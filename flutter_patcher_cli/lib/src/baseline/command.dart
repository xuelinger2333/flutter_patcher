import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../sdk/host.dart';
import 'manifest.dart';
import 'repository.dart';
import 'split.dart';
import 'store.dart';

ArgParser baselineOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('json', negatable: false)
  ..addFlag('offline', negatable: false)
  ..addOption('action',
      allowed: ['save', 'fetch', 'verify', 'release'], defaultsTo: 'verify')
  ..addOption('baseline',
      help:
          'save: completed build output (never modified); verify: extracted legacy, compile or release object.')
  ..addOption('metadata',
      help:
          'Baseline input metadata JSON (schema/version/engine/build_id/platform).')
  ..addOption('fingerprint')
  ..addOption('baseline-store',
      help: 'file://, s3:// or conditional-PUT HTTPS store.')
  ..addOption('cache-dir')
  ..addOption('flutter-sdk',
      help: 'Optional initialized SDK to check platform binding.')
  ..addOption('flavor', defaultsTo: 'default')
  ..addOption('version-code')
  ..addOption('abi', defaultsTo: 'arm64-v8a');

Future<int> baselineCommand(ArgResults args) async {
  try {
    requireSupportedHost();
    String required(String option) {
      final value = args[option] as String?;
      require(value != null && value.isNotEmpty, 'CONFIG_INVALID',
          'Missing --$option');
      return value!;
    }

    final root = managedCache(args['cache-dir'] as String?);
    final commands = Commands(root);
    final uri = args['baseline-store'] as String?;
    final offline = args['offline'] == true;
    final store = uri == null || (offline && Uri.parse(uri).scheme != 'file')
        ? null
        : BaselineStore.open(Uri.parse(uri), commands, offline: offline);
    final repository = BaselineRepository(p.join(root, 'baselines'), store);
    final sdk = args['flutter-sdk'] as String?;
    Map<String, dynamic> result;
    switch (args['action']) {
      case 'save':
        require(!offline || store is FileBaselineStore, 'CONFIG_INVALID',
            'Remote save is unavailable offline.');
        final metadata = await baselineObject(required('metadata'));
        if (sdk != null) await verifyPlatform(metadata, sdk);
        result = await repository.save(required('baseline'), metadata,
            flavor: required('flavor'),
            versionCode: required('version-code'),
            abi: required('abi'));
      case 'fetch':
        final fingerprint = required('fingerprint');
        String root;
        try {
          root = await repository.fetchCompile(fingerprint, sdkRoot: sdk);
        } on Failure catch (e) {
          if (e.code != 'BASELINE_NOT_FOUND') rethrow;
          root = await repository.fetch(fingerprint, sdkRoot: sdk);
        }
        result = {
          'status': 'baseline_verified',
          'cache': root,
          ...await verifyBaselineDir(root, sdkRoot: sdk)
        };
      case 'release':
        result = {
          'status': 'release_baseline_verified',
          ...await repository.verifyRelease(
              required('flavor'), required('version-code'),
              abi: required('abi'), sdkRoot: sdk)
        };
      default:
        result = {
          'status': 'baseline_verified',
          ...await verifyBaselineDir(required('baseline'),
              expected: args['fingerprint'] as String?, sdkRoot: sdk)
        };
    }
    stdout.writeln(jsonEncode({'command': 'baseline', ...result}));
    return 0;
  } catch (e) {
    final failure = e is Failure
        ? e
        : Failure('BASELINE_OPERATION_FAILED',
            'Baseline operation failed (${e.runtimeType}).');
    stderr.writeln(jsonEncode({
      'command': 'baseline',
      'status': 'failed',
      'code': failure.code,
      'message': failure.message
    }));
    return 2;
  }
}
