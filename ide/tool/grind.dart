// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:grinder/grinder.dart';
import 'package:intl/intl.dart';

final NumberFormat _NF = new NumberFormat.decimalPattern();

// TODO: make the deploy-test and deploy tasks incremental

final Directory BUILD_DIR = new Directory('build');
final Directory DIST_DIR = new Directory('dist');

void main([List<String> args]) {
  defineTask('setup', taskFunction: setup);

  defineTask('mode-notest', taskFunction: (c) => _changeMode(c, false));
  defineTask('mode-test', taskFunction: (c) => _changeMode(c, true));

  defineTask('compile', taskFunction: compile, depends : ['setup']);
  defineTask('deploy', taskFunction: deploy, depends : ['setup', 'mode-notest']);
  defineTask('deploy-test', taskFunction: deployTest, depends : ['setup', 'mode-test']);

  defineTask('docs', taskFunction : docs, depends : ['setup']);
  defineTask('archive', taskFunction : archive, depends : ['mode-notest', 'compile']);
  defineTask('release', taskFunction : release, depends : ['mode-notest', 'compile']);

  defineTask('clean', taskFunction: clean);

  startGrinder(args);
}

/**
 * Init needed dependencies.
 */
void setup(GrinderContext context) {
  // check to make sure we can locate the SDK
  if (sdkDir == null) {
    context.fail("Unable to locate the Dart SDK\n"
        "Please set the DART_SDK environment variable to the SDK path.\n"
        "  e.g.: 'export DART_SDK=your/path/to/dart/dart-sdk'");
  }

  PubTools pub = new PubTools();
  pub.install(context);

  _populateSdk(context);

  // copy from ./packages to ./app/packages
  copyDirectory(
      joinDir(Directory.current, ['packages']),
      joinDir(Directory.current, ['app', 'packages']),
      context);

  BUILD_DIR.createSync();
  DIST_DIR.createSync();
}

/**
 * Compile the two Spark entry-points.
 */
void compile(GrinderContext context) {
  _dart2jsCompile(context, new Directory('app'), 'spark.dart');
  context.log('');
  _dart2jsCompile(context, new Directory('app'), 'spark_test.dart');
}

/**
 * Copy all source to `build/deploy`. Do a polymer deploy to `build/deploy-out`.
 * This builds the regular (non-test) version of the app.
 */
void deploy(GrinderContext context) {
  Directory sourceDir = joinDir(BUILD_DIR, ['deploy']);
  Directory destDir = joinDir(BUILD_DIR, ['deploy-out']);

  _polymerDeploy(context, sourceDir, destDir);

  ['spark.html_bootstrap.dart', 'spark_polymer.html_bootstrap.dart']
      .forEach((e) => _dart2jsCompile(context, joinDir(destDir, ['web']), e, true));
}

/**
 * Copy all source to `build/deploy-test`. Do a polymer deploy to
 * `build/deploy-test-out`. This builds a test version of the app.
 */
void deployTest(GrinderContext context) {
  Directory sourceDir = joinDir(BUILD_DIR, ['deploy-test']);
  Directory destDir = joinDir(BUILD_DIR, ['deploy-test-out']);

  _polymerDeploy(context, sourceDir, destDir);

  ['spark.html_bootstrap.dart', 'spark_polymer.html_bootstrap.dart']
      .forEach((e) => _dart2jsCompile(context, joinDir(destDir, ['web']), e, true));
}

// Creates a release build to be uploaded to Chrome Web Store.
// It will perform the following steps:
// - Sources will be compiled in Javascript using "compile" task
// - If the current branch/repo is not releasable, we just create an archive
//   tagged with a revision number.
// - Using increaseBuildNumber, for a given revision number a.b.c where a, b
//   and c are integers, we increase c, the build number and write it to the
//   manifest.json file.
// - We duplicate the manifest.json file to build/polymer-build/web since we'll
//   create the Chrome App from here.
// - "archive" task will create a spark.zip file in dist/, based on the content
//   of build/polymer-build/web.
// - If everything is successful and no exception interrupted the process,
//   we'll commit the new manifest.json containing the updated version number
//   to the repository. The developer still needs to push it to the remote
//   repository.
// - We eventually rename dist/spark.zip to dist/spark-a.b.c.zip to reflect the
//   new version number.
void release(GrinderContext context) {
  // If repository is not original repository of Spark and the branch is not
  // master.
  if (!_canReleaseFromHere()) {
    _archiveWithRevision(context);
    return;
  }

  String version = _increaseBuildNumber(context);
  // Creating an archive of the Chrome App.
  context.log('Creating build ${version}');

  archive(context);

  _runCommandSync(
    context,
    'git commit -m "Build version ${version}" app/manifest.json');

  File file = new File('dist/spark.zip');
  String filename = 'spark-${version}.zip';
  file.renameSync('dist/${filename}');
  context.log('Created ${filename}');
  context.log('** A commit has been created, you need to push it. ***');
  print('Do you want to push to the remote git repository now? (y/n [n])');
  var line = stdin.readLineSync();
  if (line.trim() == 'y') {
    _runCommandSync(context, 'git push origin master');
  }
}

// Creates an archive of the Chrome App.
// - Sources will be compiled in Javascript using "compile" task
//
// We'll create an archive using the content of build-chrome-app.
// - Copy the compiled sources to build/chrome-app/spark
// - We clean all packages/ folders that have been duplicated into every
//   folders by the "compile" task
// - Copy the packages/ directory in build/chrome-app/spark/packages
// - Remove test
// - Zip the content of build/chrome-app-spark to dist/spark.zip
void archive(GrinderContext context) {
  // zip spark.zip . -r -q -x .*
  _runCommandSync(context, 'zip ../${DIST_DIR.path}/spark.zip . -qr -x .*',
      cwd: 'app');
  _printSize(context, new File('dist/spark.zip'));
}

void docs(GrinderContext context) {
  FileSet docFiles = new FileSet.fromDir(
      new Directory('docs'), endsWith: '.html');
  FileSet sourceFiles = new FileSet.fromDir(
      new Directory('app'), endsWith: '.dart', recurse: true);

  if (!docFiles.upToDate(sourceFiles)) {
    // TODO: once more libraries are referenced from spark.dart, we won't need
    // to explicitly pass them to dartdoc
    runSdkBinary(context, 'dartdoc',
        arguments: ['--omit-generation-time', '--no-code',
                    '--mode', 'static',
                    '--package-root', 'packages/',
                    '--include-lib', 'spark,spark.ace,spark.file_item_view,spark.html_utils,spark.split_view,spark.utils,spark.preferences,spark.workspace,spark.sdk',
                    '--include-lib', 'spark.server,spark.tcp',
                    '--include-lib', 'git,git.objects,git.zlib',
                    'app/spark.dart', 'app/lib/preferences.dart', 'app/lib/workspace.dart', 'app/lib/sdk.dart',
                    'app/lib/server.dart', 'app/lib/tcp.dart',
                    'app/lib/git.dart', 'app/lib/git_object.dart', 'app/lib/zlib.dart']);

    _runCommandSync(context,
        'zip ../dist/spark-docs.zip . -qr -x .*', cwd: 'docs');
  }
}

/**
 * Delete all generated artifacts.
 */
void clean(GrinderContext context) {
  // delete the sdk directory
  _runCommandSync(context, 'rm -rf app/sdk/lib');
  _runCommandSync(context, 'rm -f app/sdk/version');

  // delete any compiled js output
  _runCommandSync(context, 'rm -f app/*.dart.js');
  _runCommandSync(context, 'rm -f app/*.dart.precompiled.js');
  _runCommandSync(context, 'rm -f app/*.js.map');
  _runCommandSync(context, 'rm -f app/*.js.deps');

  // delete the build/ dir
  _runCommandSync(context, 'rm -rf build');
}

void _polymerDeploy(GrinderContext context, Directory sourceDir, Directory destDir) {
  _runCommandSync(context, 'rm -rf ${sourceDir.path}');
  sourceDir.createSync();
  _runCommandSync(context, 'rm -rf ${destDir.path}');
  destDir.createSync();

  // copy the app directory to target/web
  copyFile(new File('pubspec.yaml'), sourceDir);
  copyFile(new File('pubspec.lock'), sourceDir);
  copyDirectory(new Directory('app'), joinDir(sourceDir, ['web']), context);
  _runCommandSync(context, 'rm -rf ${sourceDir.path}/web/packages');
  Link link = new Link(sourceDir.path + '/packages');
  link.createSync('../../packages');

  runDartScript(context, 'packages/polymer/deploy.dart',
      arguments: ['--out', '../../${destDir.path}'],
      packageRoot: 'packages',
      workingDirectory: sourceDir.path);
}

void _dart2jsCompile(GrinderContext context, Directory target, String filePath,
                     [bool removeSymlinks = false]) {
  runSdkBinary(context, 'dart2js', arguments: [
     joinDir(target, [filePath]).path,
     '--package-root=packages',
     '--suppress-hints',
     '--suppress-warnings',
     '--out=' + joinDir(target, ['${filePath}.js']).path]);

  // clean up unnecessary (and large) files
  _runCommandSync(context, 'rm -f ${joinFile(target, ['${filePath}.js']).path}');
  _runCommandSync(context, 'rm -f ${joinFile(target, ['${filePath}.js.deps']).path}');
  _runCommandSync(context, 'rm -f ${joinFile(target, ['${filePath}.js.map']).path}');

  if (removeSymlinks) {
    // de-symlink the directory
    _removePackagesLinks(context, target);

    copyDirectory(
        joinDir(target, ['..', '..', '..', 'packages']),
        joinDir(target, ['packages']),
        context);
  }

  _printSize(context,  joinFile(target, ['${filePath}.precompiled.js']));
}

void _changeMode(GrinderContext context, bool useTestMode) {
  File configFile = joinFile(Directory.current, ['app', 'app.json']);
  configFile.writeAsStringSync('{"test-mode":${useTestMode}}');
}

// Returns the name of the current branch.
String _getBranchName() {
  return _getCommandOutput('git branch | grep "*" | sed -e "s/\* //g"');
}

// Returns the URL of the git repository.
String _getRepositoryUrl() {
  return _getCommandOutput('git config remote.origin.url');
}

// Returns the current revision identifier of the local copy.
String _getCurrentRevision() {
  return _getCommandOutput('git rev-parse HEAD | cut -c1-10');
}

// We can build a real release only if the repository is the original
// repository of spark and master is the working branch since we need to
// increase the version and commit it to the repository.
bool _canReleaseFromHere() {
  return (_getRepositoryUrl() == 'https://github.com/dart-lang/spark.git') &&
         (_getBranchName() == 'master');
}

// In case, release is performed on a non-releasable branch/repository, we just
// archive and name the archive with the revision identifier.
void _archiveWithRevision(GrinderContext context) {
  context.log('Performing archive instead.');
  archive(context);
  File file = new File('dist/spark.zip');
  String version = _getCurrentRevision();
  String filename = 'spark-rev-${version}.zip';
  file.rename('dist/${filename}');
  context.log("Created ${filename}");
}

// Increase the build number in the manifest.json file. Returns the full
// version.
String _increaseBuildNumber(GrinderContext context) {
  // Tweaking build version in manifest.
  File file = new File('app/manifest.json');
  String content = file.readAsStringSync();
  var manifestDict = JSON.decode(content);
  String version = manifestDict['version'];
  RegExp exp = new RegExp(r"(\d+\.\d+)\.(\d+)");
  Iterable<Match> matches = exp.allMatches(version);
  assert(matches.length > 0);

  Match m = matches.first;
  String majorVersion = m.group(1);
  int buildVersion = int.parse(m.group(2));
  buildVersion++;

  version = '${majorVersion}.${buildVersion}';
  manifestDict['version'] = version;
  file.writeAsStringSync(new JsonPrinter().print(manifestDict));

  // It needs to be copied to compile result directory.
  copyFile(
      joinFile(Directory.current, ['app', 'manifest.json']),
      joinDir(BUILD_DIR, ['deploy-out', 'web']));

  return version;
}

void _removePackagesLinks(GrinderContext context, Directory target) {
  target.listSync(recursive: true, followLinks: false).forEach((FileSystemEntity entity) {
    if (entity is Link && fileName(entity) == 'packages') {
      try { entity.deleteSync(); } catch (_) { }
    } else if (entity is Directory) {
      _removePackagesLinks(context, entity);
    }
  });
}

/**
 * Populate the 'app/sdk' directory from the current Dart SDK.
 */
void _populateSdk(GrinderContext context) {
  Directory srcSdkDir = sdkDir;
  Directory destSdkDir = new Directory('app/sdk');

  destSdkDir.createSync();

  File srcVersionFile = joinFile(srcSdkDir, ['version']);
  File destVersionFile = joinFile(destSdkDir, ['version']);

  FileSet srcVer = new FileSet.fromFile(srcVersionFile);
  FileSet destVer = new FileSet.fromFile(destVersionFile);

  Directory compilerDir = new Directory('packages/compiler');

  // check the state of the sdk/version file, to see if things are up-to-date
  if (!destVer.upToDate(srcVer) || !compilerDir.existsSync()) {
    // copy files over
    context.log('copying SDK');
    copyFile(srcVersionFile, destSdkDir);
    copyDirectory(joinDir(srcSdkDir, ['lib']), joinDir(destSdkDir, ['lib']), context);

    // Create a synthetic package:compiler package in the packages directory.
    // TODO(devoncarew): this would be much better as a std pub package
    compilerDir.createSync();

    _runCommandSync(context, 'rm -rf packages/compiler/compiler');
    _runCommandSync(context, 'rm -rf packages/compiler/lib');
    _runCommandSync(context, 'rm -rf app/sdk/lib/_internal/compiler/samples');
    _runCommandSync(context, 'mv app/sdk/lib/_internal/compiler packages/compiler');
    _runCommandSync(context, 'cp app/sdk/lib/_internal/libraries.dart packages/compiler');
    _runCommandSync(context, 'rm -rf app/sdk/lib/_internal/pub');
    _runCommandSync(context, 'rm -rf app/sdk/lib/_internal/dartdoc');

    // traverse directories, creating a .files json directory listing
    context.log('creating SDK directory listings');
    _createDirectoryListings(destSdkDir);
  }
}

/**
 * Recursively create `.files` json files in the given directory; these files
 * serve as directory listings.
 */
void _createDirectoryListings(Directory dir) {
  List<String> files = [];

  String parentName = fileName(dir);

  for (FileSystemEntity entity in dir.listSync(followLinks: false)) {
    String name = fileName(entity);

    // ignore hidden files and directories
    if (name.startsWith('.')) continue;

    if (entity is File) {
      files.add(name);
    } else {
      files.add("${name}/");
      _createDirectoryListings(entity);
    }
  };

  joinFile(dir, ['.files']).writeAsStringSync(JSON.encode(files));
}

void _printSize(GrinderContext context, File file) {
  int sizeKb = file.lengthSync() ~/ 1024;
  context.log('${file.path} is ${_NF.format(sizeKb)}k');
}

void _runCommandSync(GrinderContext context, String command, {String cwd}) {
  context.log(command);

  var result = Process.runSync(
      '/bin/sh', ['-c', command], workingDirectory: cwd);

  if (result.stdout.isNotEmpty) {
    context.log(result.stdout);
  }
  if (result.stderr.isNotEmpty) {
    context.log(result.stderr);
  }

  if (result.exitCode > 0) {
    context.fail("exit code ${result.exitCode}");
  }
}

String _getCommandOutput(String command) {
  return Process.runSync('/bin/sh', ['-c', command]).stdout.trim();
}

/**
 * Pretty print Json text.
 *
 * Usage:
 *     String str = new JsonPrinter().print(jsonObject);
 */
class JsonPrinter {
  String _in = '';

  JsonPrinter();

  /**
   * Given a structured, json-like object, print it to a well-formatted, valid
   * json string.
   */
  String print(dynamic json) {
    return _print(json) + '\n';
  }

  String _print(var obj) {
    if (obj is List) {
      return _printList(obj);
    } else if (obj is Map) {
      return _printMap(obj);
    } else if (obj is String) {
      return '"${obj}"';
    } else {
      return '${obj}';
    }
  }

  String _printList(List list) {
    return "[${_indent()}${list.map(_print).join(',${_newLine}')}${_unIndent()}]";
  }

  String _printMap(Map map) {
    return "{${_indent()}${map.keys.map((key) {
      return '"${key}": ${_print(map[key])}';
    }).join(',${_newLine}')}${_unIndent()}}";
  }

  String get _newLine => '\n${_in}';

  String _indent() {
    _in += '  ';
    return '\n${_in}';
  }

  String _unIndent() {
    _in = _in.substring(2);
    return '\n${_in}';
  }
}
