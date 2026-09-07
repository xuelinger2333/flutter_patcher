import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import 'artifacts.dart';

String findFlutter(String? requested) {
  if (requested != null) return p.absolute(requested);
  for (final directory in (Platform.environment['PATH'] ?? '')
      .split(Platform.isWindows ? ';' : ':')) {
    final binary =
        File(p.join(directory, Platform.isWindows ? 'flutter.bat' : 'flutter'));
    if (binary.existsSync()) {
      return p.dirname(p.dirname(binary.resolveSymbolicLinksSync()));
    }
  }
  throw Failure('FLUTTER_NOT_FOUND',
      'Flutter is not on PATH. Select it with --flutter-sdk.');
}

Future<SdkIdentity> identify(String root, Commands commands) async {
  require(
      await File(p.join(root, 'bin/cache/flutter_tools.snapshot')).exists() &&
          await File(p.join(root, 'bin/cache/dart-sdk/bin/dart')).exists(),
      'SDK_NOT_READY',
      'Selected Flutter SDK must already be initialized; doctor will not bootstrap it in place.');
  await checkSdkReady(root, commands);
  final result = await commands.run(p.join(root, 'bin/flutter'),
      ['--suppress-analytics', '--version', '--machine'],
      code: 'FLUTTER_VERSION_INVALID');
  Map<String, dynamic> version;
  try {
    version = jsonDecode(result) as Map<String, dynamic>;
  } catch (_) {
    throw Failure('FLUTTER_VERSION_INVALID',
        'Flutter did not return machine-readable version information.');
  }
  final v = version['frameworkVersion'], engine = version['engineRevision'];
  final framework = version['frameworkRevision'];
  final dart = (version['dartSdkVersion'] as String? ?? '').split(' ').first;
  require(
      v is String &&
          versionPattern.hasMatch(v) &&
          engine is String &&
          hex40.hasMatch(engine) &&
          framework is String &&
          hex40.hasMatch(framework) &&
          versionPattern.hasMatch(dart),
      'FLUTTER_VERSION_INVALID',
      'Invalid Flutter/Dart/engine version information.');
  require(
      (await File(p.join(root, 'bin/internal/engine.version')).readAsString())
              .trim() ==
          engine,
      'FLUTTER_VERSION_INVALID',
      'Selected SDK engine.version differs from flutter --version.');
  return SdkIdentity(root, v, engine, dart, framework);
}

/// Refuse SDK states that cause the Flutter launcher to rebuild itself.
Future<void> checkSdkReady(String root, Commands commands) async {
  Future<String> read(String relative) async {
    final file = File(p.join(root, relative));
    require(
        await file.exists(), 'SDK_NOT_READY', 'SDK cache missing: $relative');
    return (await file.readAsString()).trim();
  }

  require(!await File(p.join(root, 'bin/internal/bootstrap.sh')).exists(),
      'SDK_NOT_READY', 'Custom SDK bootstrap scripts are not supported.');
  final framework = (await commands
          .run('git', ['-C', root, 'rev-parse', 'HEAD'], code: 'SDK_NOT_READY'))
      .trim();
  final engine = await read('bin/internal/engine.version');
  require(
      await read('bin/cache/flutter_tools.stamp') == '$framework:' &&
          await read('bin/cache/engine.stamp') == engine &&
          await read('bin/cache/engine-dart-sdk.stamp') == engine &&
          (await read('bin/cache/engine.realm')).isEmpty,
      'SDK_NOT_READY',
      'Selected SDK caches are stale; initialize your stock SDK before running doctor.');
  final pubspec = File(p.join(root, 'packages/flutter_tools/pubspec.yaml'));
  final lockfile = File(p.join(root, 'packages/flutter_tools/pubspec.lock'));
  require(
      await pubspec.exists() &&
          await lockfile.exists() &&
          !(await pubspec.lastModified())
              .isAfter(await lockfile.lastModified()),
      'SDK_NOT_READY',
      'Selected SDK Flutter tool dependencies are stale.');
}

class EnvironmentBuilder {
  final String cache;
  final Commands commands;
  final bool offline;
  EnvironmentBuilder(this.cache, this.commands, {this.offline = false});

  Future<String> prepare(
      SdkIdentity sdk, ArtifactStore store, Map<String, dynamic> engine) async {
    final target = p.join(cache, 'flutter', sdk.version);
    await rejectLinks(target);
    final marker = p.join(target, '.flutter-patcher-sdk.json');
    var ready = false;
    if (await File(marker).exists()) {
      final state = await readObject(marker);
      ready = state['framework_commit'] == sdk.framework &&
          state['engine_commit'] == sdk.engine;
    }
    if (!ready) {
      require(!offline, 'SDK_NOT_READY',
          'The managed SDK is not cached for offline use.');
      if (await Directory(target).exists()) await quarantine(target);
      await Directory(p.dirname(target)).create(recursive: true);
      final staging = temporaryName(target);
      await commands.run(
          'git',
          [
            'clone',
            '--depth',
            '1',
            '--branch',
            sdk.version,
            'https://github.com/flutter/flutter.git',
            staging
          ],
          code: 'SDK_PREPARE_FAILED');
      final commit =
          (await commands.run('git', ['-C', staging, 'rev-parse', 'HEAD']))
              .trim();
      require(commit == sdk.framework, 'SDK_PREPARE_FAILED',
          'Flutter version tag differs from the selected SDK revision.');
      // Bootstrap stock downloads before constructing/using the local Maven mirror.
      await commands.run(p.join(staging, 'bin/flutter'),
          ['--suppress-analytics', 'precache', '--android'],
          code: 'SDK_PREPARE_FAILED');
      require(
          (await File(p.join(staging, 'bin/internal/engine.version'))
                      .readAsString())
                  .trim() ==
              sdk.engine,
          'SDK_PREPARE_FAILED',
          'Managed SDK engine revision differs.');
      await writeObject(
          p.join(staging, '.flutter-patcher-sdk.json'), sdk.toJson());
      await Directory(staging).rename(target);
    }
    final commit =
        (await commands.run('git', ['-C', target, 'rev-parse', 'HEAD'])).trim();
    require(commit == sdk.framework, 'SDK_PREPARE_FAILED',
        'Managed SDK checkout changed.');
    final snapshot = store.file(sdk, 'engine', 'gen_snapshot-linux-x64');
    final installed = p.join(target,
        'bin/cache/artifacts/engine/android-arm64-release/linux-x64/gen_snapshot');
    await rejectLinks(installed);
    await Directory(p.dirname(installed)).create(recursive: true);
    if (!await File(installed).exists() ||
        await hashFile(installed) != await hashFile(snapshot)) {
      final stage = temporaryName(installed);
      await File(snapshot).copy(stage);
      await commands.run('chmod', ['755', stage]);
      await File(stage).rename(installed);
    }
    await commands.run('chmod', ['755', installed]);
    require(await hashFile(installed) == await hashFile(snapshot),
        'ENGINE_ARTIFACT_MISMATCH', 'Installed gen_snapshot mismatch.');
    await mirror(sdk, store, engine);
    return target;
  }

  Future<String> mirror(
      SdkIdentity sdk, ArtifactStore store, Map<String, dynamic> engine) async {
    final root =
        p.join(cache, 'mirrors', sdk.version, engine['build_id'] as String);
    await rejectLinks(root);
    for (final row in (engine['files'] as List)
        .where((row) => row['role'] != 'gen_snapshot')) {
      final coordinate = (row['maven'] as String).split(':');
      final name = coordinate[1], version = coordinate[2];
      final folder =
          p.join(root, 'download.flutter.io/io/flutter', name, version);
      await rejectLinks(folder);
      await Directory(folder).create(recursive: true);
      final jar = p.join(folder, '$name-$version.jar');
      await rejectLinks(jar);
      await File(store.file(sdk, 'engine', row['name'] as String)).copy(jar);
      final pom = p.join(folder, '$name-$version.pom');
      await rejectLinks(pom);
      await File(pom).writeAsString(
          '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>'
          '<groupId>io.flutter</groupId><artifactId>$name</artifactId><version>$version</version>'
          '<packaging>jar</packaging></project>\n');
    }
    return root;
  }

  String sdkInput(SdkIdentity sdk, String managed, String relative) {
    final selected = p.join(sdk.root, relative);
    return File(selected).existsSync() ? selected : p.join(managed, relative);
  }

  Future<String> yamlCache(
      SdkIdentity sdk, String managed, String tools) async {
    final platform = sdkInput(sdk, managed,
        'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill');
    final frontend = sdkInput(sdk, managed,
        'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot');
    require(await File(platform).exists() && await File(frontend).exists(),
        'SDK_NOT_READY', 'Matching SDK compiler inputs are missing.');
    final inputs = <String, dynamic>{
      ...sdk.toJson(),
      'tools_sha256': await hashFile(tools),
      'platform_sha256': await hashFile(platform),
      'frontend_sha256': await hashFile(frontend)
    };
    final sources = await Directory(p.join(sdk.root, 'packages/flutter/lib'))
        .list(recursive: true)
        .where((entry) => entry is File && entry.path.endsWith('.dart'))
        .cast<File>()
        .toList();
    sources.sort((a, b) => a.path.compareTo(b.path));
    final sourceHashes = <String>[];
    for (final file in sources) {
      sourceHashes.add(
          '${p.relative(file.path, from: sdk.root)}:${await hashFile(file.path)}');
    }
    inputs['framework_sources_sha256'] =
        sha256.convert(utf8.encode(sourceHashes.join('\n'))).toString();
    inputs['framework_pubspec_sha256'] =
        await hashFile(p.join(sdk.root, 'packages/flutter/pubspec.yaml'));
    final key = sha256.convert(utf8.encode(jsonEncode(inputs))).toString();
    final directory = p.join(cache, 'yaml', sdk.version, key);
    await rejectLinks(directory);
    final names = [
      'protocol_interface-${sdk.version}.yaml',
      'platform_privates-${sdk.version}.yaml'
    ];
    if (await File(p.join(directory, 'state.json')).exists()) {
      try {
        final state = await readObject(p.join(directory, 'state.json'));
        for (final name in names) {
          final file = p.join(directory, name);
          await rejectLinks(file);
          require(await hashFile(file) == (state['outputs'] as Map)[name],
              'YAML_CACHE_INVALID', 'Cached YAML hash differs.');
          _validateYaml(await File(file).readAsString());
        }
        return directory;
      } catch (_) {
        await quarantine(directory);
      }
    } else if (await Directory(directory).exists()) {
      await quarantine(directory);
    }
    final staging = temporaryName(directory);
    final probe = p.join(staging, 'probe');
    await Directory(probe).create(recursive: true);
    await File(p.join(probe, 'pubspec.yaml')).writeAsString(
        'name: flutter_patcher_sdk_probe\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n'
        'dependencies:\n  flutter:\n    path: ${jsonEncode(p.join(sdk.root, 'packages/flutter'))}\n');
    await File(p.join(probe, 'main.dart')).writeAsString(
        "import 'package:flutter/material.dart';\nvoid main() { runApp(const SizedBox()); }\n");
    await commands.run(p.join(managed, 'bin/flutter'),
        ['--suppress-analytics', 'pub', 'get', if (offline) '--offline'],
        cwd: probe, code: 'YAML_GENERATION_FAILED');
    final dill = p.join(probe, 'linked.dill');
    await commands.run(
        p.join(sdk.root, 'bin/cache/dart-sdk/bin/dartaotruntime'),
        [
          frontend,
          '--sdk-root',
          '${p.dirname(platform)}/',
          '--target',
          'flutter',
          '--no-aot',
          '--no-tfa',
          '--link-platform',
          '--packages',
          p.join(probe, '.dart_tool/package_config.json'),
          '--output-dill',
          dill,
          p.join(probe, 'main.dart')
        ],
        cwd: probe,
        code: 'YAML_GENERATION_FAILED');
    await commands.run(
        sdk.dart,
        [
          tools,
          'gen-protocol-interface',
          '--dill',
          dill,
          '--out',
          p.join(staging, names[0])
        ],
        code: 'YAML_GENERATION_FAILED');
    await commands.run(
        sdk.dart,
        [
          tools,
          'gen-platform-privates',
          '--platform',
          platform,
          '--out',
          p.join(staging, names[1])
        ],
        code: 'YAML_GENERATION_FAILED');
    final outputs = <String, String>{};
    for (final name in names) {
      _validateYaml(await File(p.join(staging, name)).readAsString());
      outputs[name] = await hashFile(p.join(staging, name));
    }
    await writeObject(
        p.join(staging, 'state.json'), {'inputs': inputs, 'outputs': outputs});
    await Directory(staging).rename(directory);
    return directory;
  }

  void _validateYaml(String text) {
    final document = loadYaml(text);
    require(document is YamlMap && document.isNotEmpty,
        'YAML_GENERATION_FAILED', 'Generator produced invalid/empty YAML.');
  }

  Future<void> pairSmoke(SdkIdentity sdk, String managed) async {
    final work = p.join(cache, 'verification',
        '${sdk.version}-${DateTime.now().microsecondsSinceEpoch}');
    await Directory(work).create(recursive: true);
    await File(p.join(work, 'main.dart'))
        .writeAsString("void main() { print('WP2_PAIR_OK'); }\n");
    await writeObject(p.join(work, 'package_config.json'),
        {'configVersion': 2, 'packages': []});
    final platform = sdkInput(sdk, managed,
        'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill');
    final frontend = sdkInput(sdk, managed,
        'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot');
    await commands.run(
        p.join(sdk.root, 'bin/cache/dart-sdk/bin/dartaotruntime'),
        [
          frontend,
          '--sdk-root',
          '${p.dirname(platform)}/',
          '--target',
          'flutter',
          '--target-os',
          'android',
          '--aot',
          '--tfa',
          '--packages',
          p.join(work, 'package_config.json'),
          '--output-dill',
          p.join(work, 'main.dill'),
          p.join(work, 'main.dart')
        ],
        code: 'ENGINE_ARTIFACT_MISMATCH');
    final snapshot = p.join(managed,
        'bin/cache/artifacts/engine/android-arm64-release/linux-x64/gen_snapshot');
    final elf = p.join(work, 'libapp.so');
    await commands.run(
        snapshot,
        [
          '--snapshot_kind=app-aot-elf',
          '--elf=$elf',
          p.join(work, 'main.dill')
        ],
        code: 'ENGINE_ARTIFACT_MISMATCH');
    final bytes = await File(elf).readAsBytes();
    require(
        bytes.length > 20 &&
            bytes.take(4).join(',') == '127,69,76,70' &&
            bytes[18] == 183 &&
            bytes[19] == 0,
        'ENGINE_ARTIFACT_MISMATCH',
        'gen_snapshot did not produce arm64 AOT ELF.');
  }
}

Future<void> verifyApk(String apk, Map<String, dynamic> engine) async {
  require(await File(apk).exists(), 'ENGINE_INJECTION_FAILED',
      'APK does not exist: $apk');
  final expected = ((engine['files'] as List)
          .singleWhere((row) => row['role'] == 'engine')['contents'] as List)
      .single;
  final entries = ZipDecoder()
      .decodeBytes(await File(apk).readAsBytes())
      .files
      .where((entry) => entry.name == 'lib/arm64-v8a/libflutter.so')
      .toList();
  require(
      entries.length == 1 &&
          entries.single.content.length == expected['size'] &&
          sha256.convert(entries.single.content).toString() ==
              expected['sha256'],
      'ENGINE_INJECTION_FAILED',
      'APK arm64 libflutter.so differs from the engine manifest.');
}
