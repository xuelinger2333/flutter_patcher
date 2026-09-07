import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'core.dart';
import 'sdk/artifacts.dart';
import 'sdk/environment.dart';

const releaseBase =
    'https://github.com/xuelinger2333/flutter_patcher_artifacts/releases/download';
const supportTable =
    'https://api.github.com/repos/xuelinger2333/flutter_patcher_artifacts/contents/supported_versions.txt';

ArgParser parser() {
  final doctor = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('json',
        negatable: false, help: 'Print a structured diagnostic report.')
    ..addFlag('offline',
        negatable: false, help: 'Use verified local caches only.')
    ..addOption('flutter-sdk',
        help: 'Select the Flutter SDK; defaults to Flutter on PATH.')
    ..addOption('cache-dir',
        help:
            'Managed directory under ~/.flutter_patcher or .dart_tool/flutter_patcher.')
    ..addOption('artifacts-url',
        defaultsTo: releaseBase,
        help: 'Maintainer/test override for the release download base.')
    ..addOption('supported-versions-url',
        defaultsTo: supportTable,
        help: 'Maintainer/test override for the support table.')
    ..addOption('public-key',
        help: 'Optional signing public key file to check.')
    ..addOption('private-key',
        help: 'Optional signing private key file to check.')
    ..addOption('baseline-store',
        help: 'Optional file:// or HTTPS baseline store to probe.')
    ..addOption('baseline',
        help: 'Optional extracted baseline directory for file-presence checks.')
    ..addOption('version-code',
        help: 'Optional versionCode for a file-store release sidecar check.')
    ..addOption('flavor', help: 'Flavor used in the release sidecar filename.')
    ..addOption('apk',
        help: 'Optional existing APK whose engine should be checked.');
  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', negatable: false)
    ..addCommand('doctor', doctor);
}

Future<int> runCli(List<String> arguments) async {
  final args = parser();
  ArgResults parsed;
  try {
    if (arguments.isNotEmpty &&
        ['build', 'patch', 'publish', 'keys'].contains(arguments.first)) {
      throw Failure('COMMAND_NOT_IMPLEMENTED',
          '${arguments.first} belongs to a later implementation step; WP-2 provides doctor.');
    }
    parsed = args.parse(arguments);
    require(
        parsed.rest.isEmpty, 'USAGE_ERROR', 'Unexpected positional arguments.');
    if (parsed['version'] == true) {
      stdout.writeln('flutter_patcher_cli 2.0.0-dev.1');
      return 0;
    }
    if (parsed['help'] == true || parsed.command == null) {
      stdout.writeln(
          'flutter_patcher doctor [options]\n\n${args.commands['doctor']!.usage}');
      return 0;
    }
    if (parsed.command!['help'] == true) {
      stdout.writeln(args.commands['doctor']!.usage);
      return 0;
    }
    require(parsed.rest.isEmpty && parsed.command!.rest.isEmpty, 'USAGE_ERROR',
        'Unexpected positional arguments.');
    return await doctor(parsed.command!);
  } on FormatException catch (error) {
    stderr.writeln('USAGE_ERROR: ${error.message}');
    return 2;
  } on Failure catch (error) {
    stderr.writeln(error);
    return 2;
  }
}

Future<int> doctor(ArgResults args) async {
  final checks = <Map<String, dynamic>>[];
  final watch = Stopwatch()..start();
  final downloads = Downloads(offline: args['offline'] as bool);
  final report = <String, dynamic>{
    'command': 'doctor',
    'scope': 'WP-2 toolchain',
    'checks': checks
  };
  RandomAccessFile? lock;
  var current = 'configuration';
  var success = false;
  Future<void> check(
      String id, Future<void> Function() action, String message) async {
    current = id;
    await action();
    checks.add({'id': id, 'status': 'passed', 'message': message});
  }

  void pending(String id, String message) =>
      checks.add({'id': id, 'status': 'not_run', 'message': message});
  try {
    require(Platform.isLinux, 'HOST_UNSUPPORTED',
        'M1 requires Linux x64, including x64 WSL2.');
    final home = Platform.environment['HOME'];
    require(home != null, 'CONFIG_INVALID', 'HOME is not set.');
    final defaultRoot = p.join(home!, '.flutter_patcher');
    final cache =
        p.normalize(p.absolute(args['cache-dir'] as String? ?? defaultRoot));
    final projectRoot =
        p.join(Directory.current.path, '.dart_tool/flutter_patcher');
    require(
        cache == defaultRoot ||
            p.isWithin(defaultRoot, cache) ||
            cache == projectRoot ||
            p.isWithin(projectRoot, cache),
        'CONFIG_INVALID',
        'Cache must be under ~/.flutter_patcher or this project\'s .dart_tool/flutter_patcher.');
    await rejectLinks(cache);
    final commands = Commands(cache);
    await check('host', () async {
      final arch = (await commands.run('uname', ['-m'])).trim();
      require(arch == 'x86_64', 'HOST_UNSUPPORTED',
          'M1 gen_snapshot requires Linux x64; detected $arch.');
    }, 'Linux x64');
    await Directory(cache).create(recursive: true);
    await rejectLinks(p.join(cache, 'doctor.lock'));
    lock = await File(p.join(cache, 'doctor.lock')).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    final base = Uri.parse(args['artifacts-url'] as String);
    final support = Uri.parse(args['supported-versions-url'] as String);
    Downloads.validateUri(base);
    Downloads.validateUri(support);
    final store = ArtifactStore(cache, base, support, downloads);
    late SdkIdentity sdk;
    await check('flutter_sdk', () async {
      final selected =
          await Directory(findFlutter(args['flutter-sdk'] as String?))
              .resolveSymbolicLinks();
      sdk = await identify(selected, commands);
      require(
          selected != p.join(cache, 'flutter', sdk.version),
          'CONFIG_INVALID',
          'Select your stock SDK, not the managed SDK that doctor modifies.');
      report['sdk'] = {...sdk.toJson(), 'path': selected};
    }, 'Selected SDK identity verified');
    await check('supported_version', () => store.checkSupport(sdk.version),
        'Flutter version is supported');
    late Map<String, dynamic> engine, toolsManifest;
    await check('engine_artifacts', () async {
      engine = await store.obtain('engine', sdk);
    }, 'Engine, gen_snapshot and embedding size/hash/format verified');
    await check('tools_artifacts', () async {
      toolsManifest = await store.obtain('tools', sdk);
    }, 'Unified dill size/hash/format and Dart version verified');
    report['engine_build_id'] = engine['build_id'];
    report['tools_builder_commit'] = toolsManifest['builder_repo_commit'];
    final environment =
        EnvironmentBuilder(cache, commands, offline: downloads.offline);
    late String managed;
    await check('parallel_sdk', () async {
      managed = await environment.prepare(sdk, store, engine);
    }, 'Managed SDK and local Maven mirror prepared');
    report['managed_sdk'] = managed;
    report['maven_mirror'] =
        p.join(cache, 'mirrors', sdk.version, engine['build_id'] as String);
    final tool =
        store.file(sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill');
    await check('tool_smoke', () async {
      final usage = await commands.run(sdk.dart, [tool, '--help']);
      final bytecode =
          await commands.run(sdk.dart, [tool, 'bytecode', '--help']);
      require(
          usage.contains('gen-protocol-interface') &&
              usage.contains('gen-platform-privates') &&
              bytecode.contains('--[no-]tfa') &&
              bytecode.contains('--[no-]aot-only'),
          'TOOLS_ARTIFACT_MISSING',
          'Required tool subcommands/compiler flags are missing.');
    }, 'Downloaded tool and bytecode help run without source packages');
    await check('yaml_cache', () async {
      report['yaml_cache'] = await environment.yamlCache(sdk, managed, tool);
    }, 'SDK-specific protocol and platform YAML generated or validated');
    await check('engine_pair', () => environment.pairSmoke(sdk, managed),
        'Downloaded gen_snapshot compiled a minimal arm64 AOT ELF');
    final pub = args['public-key'] as String?,
        secret = args['private-key'] as String?;
    if (pub == null && secret == null) {
      pending('signing_key_files',
          'No key files supplied; signing/key generation is not verified.');
    } else {
      await check('signing_key_files', () async {
        require(
            pub != null &&
                secret != null &&
                await File(pub).exists() &&
                await File(secret).exists() &&
                await File(pub).length() > 0 &&
                await File(secret).length() > 0,
            'KEYS_MISSING',
            'Both readable, nonempty public/private key files are required.');
      }, 'Key files exist; cryptographic format/signing is not verified');
    }
    final uri = args['baseline-store'] as String?;
    if (uri == null) {
      pending('baseline_store',
          'No baseline store supplied (WP-4 integration pending).');
    } else {
      await check(
          'baseline_store',
          () => probeStore(Uri.parse(uri), downloads.offline),
          'Configured store is reachable; archive read/write semantics are not verified');
    }
    final baseline = args['baseline'] as String?;
    if (baseline == null) {
      pending('baseline_files',
          'No extracted baseline supplied (WP-4 integration pending).');
    } else {
      await check('baseline_files', () async {
        for (final name in [
          'app.dill',
          'dynamic_interface.yaml',
          'package_config.json',
          'libapp.so'
        ]) {
          require(await File(p.join(baseline, name)).exists(),
              'BASELINE_NOT_FOUND', 'Baseline file missing: $name');
        }
      }, 'Required baseline files exist; fingerprint/archive validation belongs to WP-4');
    }
    final versionCode = args['version-code'] as String?,
        flavor = args['flavor'] as String?;
    if (versionCode == null || flavor == null || uri == null) {
      pending('release_baseline',
          'Supply file:// store, --version-code and --flavor for a sidecar presence check.');
    } else {
      await check('release_baseline', () async {
        require(
            RegExp(r'^\d+$').hasMatch(versionCode) &&
                RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(flavor),
            'CONFIG_INVALID',
            'Invalid versionCode/flavor.');
        final storeUri = Uri.parse(uri);
        require(storeUri.scheme == 'file', 'BASELINE_STORE_UNSUPPORTED',
            'Release-sidecar checks currently support file:// stores.');
        final sidecar = File(p.join(storeUri.toFilePath(),
            'release-$flavor-$versionCode-arm64-v8a.json'));
        require(await sidecar.exists(), 'BASELINE_NOT_FOUND',
            'Release sidecar is missing: ${sidecar.path}');
        final data = await readObject(sidecar.path);
        require(
            data['fingerprint'] is String &&
                hex64.hasMatch(data['fingerprint']),
            'BASELINE_NOT_FOUND',
            'Sidecar fingerprint is missing/invalid.');
      }, 'VersionCode/flavor sidecar exists; full baseline binding awaits WP-4');
    }
    final apk = args['apk'] as String?;
    if (apk == null) {
      pending(
          'apk_engine', 'No APK supplied; actual build injection awaits WP-5.');
    } else {
      await check('apk_engine', () => verifyApk(apk, engine),
          'APK arm64 engine hash matches the selected engine manifest');
    }
    pending('device_a1',
        'Device execution and the A1 update flow are outside WP-2.');
    success = true;
  } on Failure catch (error) {
    checks.add({
      'id': current,
      'status': 'failed',
      'code': error.code,
      'message': error.message
    });
    stderr.writeln(error);
  } catch (error) {
    checks.add({
      'id': current,
      'status': 'failed',
      'code': 'DOCTOR_FAILED',
      'message': '$error'
    });
    stderr.writeln('DOCTOR_FAILED: $error');
  } finally {
    await lock?.close();
  }
  report.addAll({
    'status': success ? 'toolchain_ready' : 'failed',
    'all_checks_complete': false,
    'network_requests': downloads.requests,
    'elapsed_ms': watch.elapsedMilliseconds
  });
  if (args['json'] == true) {
    stdout.writeln(jsonEncode(report));
  } else {
    for (final item in checks) {
      stdout.writeln('[${item['status']}] ${item['id']}: ${item['message']}');
    }
    stdout.writeln(success
        ? 'Toolchain ready. Project/device checks above may remain unverified.'
        : 'Doctor failed.');
  }
  return success ? 0 : 1;
}

Future<void> probeStore(Uri uri, bool offline) async {
  if (uri.scheme == 'file') {
    require(await Directory.fromUri(uri).exists(), 'BASELINE_STORE_UNREACHABLE',
        'Baseline directory does not exist.');
    await Directory.fromUri(uri).list().take(1).toList();
    return;
  }
  require(!offline, 'BASELINE_STORE_UNREACHABLE',
      'Remote store reachability cannot be verified offline.');
  Downloads.validateUri(uri);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.openUrl('HEAD', uri);
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 30));
    require(
        response.statusCode >= 200 && response.statusCode < 300,
        'BASELINE_STORE_UNREACHABLE',
        'Store returned HTTP ${response.statusCode}.');
  } finally {
    client.close(force: true);
  }
}
