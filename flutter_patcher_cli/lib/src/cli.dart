import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'core.dart';
import 'sdk/artifacts.dart';
import 'sdk/environment.dart';
import 'interfaces/pipeline.dart';
import 'baseline/command.dart';
import 'baseline/manifest.dart';
import 'baseline/repository.dart';
import 'baseline/store.dart';
import 'build/command.dart';
import 'patch/command.dart';
import 'mock/command.dart';
import 'keys/command.dart';

const releaseBase =
    'https://github.com/xuelinger2333/flutter_patcher_artifacts/releases/download';
const supportTable =
    'https://api.github.com/repos/xuelinger2333/flutter_patcher_artifacts/contents/supported_versions.txt';

ArgParser environmentOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('json',
      negatable: false, help: 'Print a structured diagnostic report.')
  ..addFlag('offline',
      negatable: false, help: 'Use verified local caches only.')
  ..addFlag('refresh-tools',
      negatable: false,
      help:
          'Re-download and verify tools before replacing their cache (online only).')
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
  ..addOption('public-key', help: 'Optional signing public key file to check.')
  ..addOption('private-key',
      help: 'Optional signing private key file to check.')
  ..addOption('baseline-store',
      help: 'Optional file://, s3:// or HTTPS baseline store to probe.')
  ..addOption('baseline',
      help: 'Optional extracted baseline directory for full integrity checks.')
  ..addOption('version-code',
      help: 'Optional versionCode for a release sidecar binding check.')
  ..addOption('flavor', help: 'Flavor used in the release sidecar filename.')
  ..addOption('apk',
      help: 'Optional existing APK whose engine should be checked.');

ArgParser parser() {
  final patch = environmentOptions()
    ..addOption('project')
    ..addOption('target', defaultsTo: 'lib/main.dart')
    ..addOption('out')
    ..addOption('fingerprint')
    ..addOption('seq')
    ..addOption('previous-seq')
    ..addMultiOption('assets',
        help: 'Asset keys to override; omitted selects changed assets.')
    ..addOption('strategy', defaultsTo: 'so', allowed: ['so', 'bytecode']);
  final build = environmentOptions()
    ..addOption('project',
        help: 'Application source directory; builds use an isolated copy.')
    ..addOption('target', defaultsTo: 'lib/main.dart')
    ..addOption('out', help: 'New APK/report output directory.')
    ..addOption('strategy', defaultsTo: 'so', allowed: ['so', 'bytecode']);
  final doctor = environmentOptions();
  final interfaces = environmentOptions()
    ..addOption('dill', help: 'Unannotated baseline app.dill.')
    ..addOption('module',
        help: 'Dart module source to validate the new host interface against.')
    ..addOption('packages', help: 'Module package_config.json.')
    ..addOption('own', help: 'Comma-separated application package names.')
    ..addOption('out',
        help:
            'New output directory; defaults under .dart_tool/flutter_patcher.')
    ..addOption('mode', defaultsTo: 'lean', allowed: ['lean', 'whole'])
    ..addOption('max-rounds', defaultsTo: '5');
  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', negatable: false)
    ..addCommand('doctor', doctor)
    ..addCommand('build', build)
    ..addCommand('patch', patch)
    ..addCommand('publish', publishOptions())
    ..addCommand('baseline', baselineOptions())
    ..addCommand('keys', keysOptions())
    ..addCommand('interface', interfaces);
}

Future<int> runCli(List<String> arguments) async {
  final args = parser();
  ArgResults parsed;
  try {
    parsed = args.parse(arguments);
    require(
        parsed.rest.isEmpty, 'USAGE_ERROR', 'Unexpected positional arguments.');
    if (parsed['version'] == true) {
      stdout.writeln('flutter_patcher_cli 2.0.0-dev.1');
      return 0;
    }
    if (parsed['help'] == true || parsed.command == null) {
      stdout.writeln(
          'flutter_patcher keys init [--out <new-directory>]\nflutter_patcher doctor [options]\nflutter_patcher interface [options]\nflutter_patcher baseline [options]\nflutter_patcher build android --strategy bytecode [options]\nflutter_patcher patch android --strategy bytecode [options]\nflutter_patcher publish --out <local-mock-directory> [options]\n\n${args.commands['doctor']!.usage}');
      return 0;
    }
    if (parsed.command!['help'] == true) {
      stdout.writeln(args.commands[parsed.command!.name]!.usage);
      return 0;
    }
    if (parsed.command!.name == 'build') {
      return await buildCommand(parsed.command!);
    }
    if (parsed.command!.name == 'keys') {
      try {
        return await keysCommand(parsed.command!);
      } on IOException {
        throw Failure('KEYS_IO_ERROR',
            'Key initialization failed; check output permissions and required local tools.');
      }
    }
    if (parsed.command!.name == 'patch') {
      return await patchCommand(parsed.command!);
    }
    if (parsed.command!.name == 'publish') {
      try {
        return await publishCommand(parsed.command!);
      } on IOException catch (error) {
        throw Failure('MOCK_IO_ERROR',
            'Local mock operation failed (${error.runtimeType})');
      }
    }
    require(parsed.rest.isEmpty && parsed.command!.rest.isEmpty, 'USAGE_ERROR',
        'Unexpected positional arguments.');
    if (parsed.command!.name == 'baseline') {
      return await baselineCommand(parsed.command!);
    }
    return await doctor(parsed.command!,
        generateInterface: parsed.command!.name == 'interface');
  } on FormatException catch (error) {
    stderr.writeln('USAGE_ERROR: ${error.message}');
    return 2;
  } on Failure catch (error) {
    stderr.writeln(error);
    return 2;
  }
}

Future<int> doctor(ArgResults args, {bool generateInterface = false}) async {
  final checks = <Map<String, dynamic>>[];
  final watch = Stopwatch()..start();
  final downloads = Downloads(offline: args['offline'] as bool);
  final report = <String, dynamic>{
    'command': generateInterface ? 'interface' : 'doctor',
    'scope':
        generateInterface ? 'WP-3 interface preparation' : 'WP-2 toolchain',
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
    require(!(args['offline'] == true && args['refresh-tools'] == true),
        'CONFIG_INVALID', '--refresh-tools cannot be used offline.');
    InterfaceRequest? interfaceRequest;
    if (generateInterface) {
      String input(String name) {
        final value = args[name] as String?;
        require(value != null && value.isNotEmpty, 'CONFIG_INVALID',
            'Missing --$name');
        return value!;
      }

      interfaceRequest = InterfaceRequest(
          dill: p.absolute(input('dill')),
          module: p.absolute(input('module')),
          packages: p.absolute(input('packages')),
          own: input('own').split(','),
          mode: args['mode'] as String,
          maxRounds: int.tryParse(args['max-rounds'] as String) ?? 0,
          output: p.absolute(args['out'] as String? ??
              p.join('.dart_tool/flutter_patcher/interfaces',
                  DateTime.now().microsecondsSinceEpoch.toString())));
      await interfaceRequest.validate();
    }
    require(Platform.isLinux, 'HOST_UNSUPPORTED',
        'M1 requires Linux x64, including x64 WSL2.');
    final cache = managedCache(args['cache-dir'] as String?);
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
      toolsManifest = await store.obtain('tools', sdk,
          refresh: args['refresh-tools'] as bool);
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
      report['yaml_cache'] = await environment.yamlCache(sdk, managed, tool,
          requireIndex: generateInterface);
    }, 'SDK-specific protocol and platform YAML generated or validated');
    await check('engine_pair', () => environment.pairSmoke(sdk, managed),
        'Downloaded gen_snapshot compiled a minimal arm64 AOT ELF');
    if (interfaceRequest != null) {
      await check('interface', () async {
        report['interface'] = await InterfacePipeline(commands, sdk, tool,
                managed, report['yaml_cache'] as String, environment)
            .generate(interfaceRequest!);
      }, 'New host interface converged under bytecode validation; host/device execution not verified');
    }
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
      pending('baseline_store', 'No baseline store supplied.');
    } else {
      await check(
          'baseline_store',
          () => BaselineStore.open(Uri.parse(uri), commands,
                  offline: downloads.offline)
              .probe(),
          'Configured baseline store is reachable; write authorization is checked during save');
    }
    final baseline = args['baseline'] as String?;
    if (baseline == null) {
      pending('baseline_files', 'No extracted baseline supplied.');
    } else {
      await check('baseline_files', () async {
        final m = await verifyBaseline(baseline, sdkRoot: sdk.root);
        require(m['runtime_bootstrap'] != false, 'BASELINE_NOT_RELEASE',
            'Pipeline validation baseline is not a runtime-enabled release.');
        require(
            m['flutter_version'] == sdk.version &&
                m['engine_commit'] == sdk.engine &&
                m['build_id'] == engine['build_id'],
            'BASELINE_FINGERPRINT_MISMATCH',
            'Baseline differs from selected Flutter/engine build.');
      }, 'Baseline manifest, files, interface detail, fingerprint and SDK/engine binding verified');
    }
    final versionCode = args['version-code'] as String?,
        flavor = args['flavor'] as String?;
    if (versionCode == null || flavor == null || uri == null) {
      pending('release_baseline',
          'Supply baseline store, --version-code and --flavor to verify release binding.');
    } else {
      await check('release_baseline', () async {
        require(
            RegExp(r'^\d+$').hasMatch(versionCode) &&
                RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(flavor),
            'CONFIG_INVALID',
            'Invalid versionCode/flavor.');
        final repository = BaselineRepository(
            p.join(cache, 'baselines'),
            BaselineStore.open(Uri.parse(uri), commands,
                offline: downloads.offline));
        final data = await repository.verifyRelease(flavor, versionCode,
            sdkRoot: sdk.root);
        require(
            data['flutter_version'] == sdk.version &&
                data['engine_commit'] == sdk.engine &&
                data['build_id'] == engine['build_id'],
            'BASELINE_FINGERPRINT_MISMATCH',
            'Release baseline differs from selected engine build.');
      }, 'Release sidecar is bound to a verified baseline and selected engine build');
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
    'status': success
        ? (generateInterface ? 'interface_validated' : 'toolchain_ready')
        : 'failed',
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
        ? (generateInterface
            ? 'Interface validated. Host build/device execution remain unverified.'
            : 'Toolchain ready. Project/device checks above may remain unverified.')
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
