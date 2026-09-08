import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../sdk/artifacts.dart';
import '../sdk/environment.dart';

const wholeSelectors = [
  '-',
  '+',
  '*',
  'get:index',
  'relativeError',
  'absoluteError'
];

class InterfaceRequest {
  final String dill, module, packages, output, mode;
  final List<String> own;
  final int maxRounds;
  InterfaceRequest(
      {required this.dill,
      required this.module,
      required this.packages,
      required this.output,
      required this.own,
      this.mode = 'lean',
      this.maxRounds = 5});

  Future<void> validate() async {
    require(
        ['lean', 'whole'].contains(mode) && maxRounds >= 1 && maxRounds <= 5,
        'CONFIG_INVALID',
        'Interface mode must be lean/whole and rounds must be 1..5.');
    require(
        own.isNotEmpty &&
            own.every((s) => RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(s)),
        'CONFIG_INVALID',
        'Explicit valid --own packages are required.');
    for (final file in [dill, module, packages]) {
      require(await File(file).exists(), 'INTERFACE_INPUT_MISSING',
          'Missing input: $file');
    }
    await rejectLinks(output);
    require(
        !await FileSystemEntity.isDirectory(output) &&
            !await File(output).exists(),
        'CONFIG_INVALID',
        'Use a new interface output directory: $output');
  }
}

/// Prepares a new host interface. Never edits a previously published baseline.
class InterfacePipeline {
  final Commands commands;
  final SdkIdentity sdk;
  final String tool, managed, yamlCache;
  final EnvironmentBuilder environment;
  InterfacePipeline(this.commands, this.sdk, this.tool, this.managed,
      this.yamlCache, this.environment);

  Future<Map<String, dynamic>> generate(InterfaceRequest request) async {
    await request.validate();
    require(
        !p.equals(p.absolute(request.output), p.absolute(sdk.root)) &&
            !p.isWithin(p.absolute(sdk.root), p.absolute(request.output)),
        'CONFIG_INVALID',
        'Interface output must not modify the selected Flutter SDK.');
    final usage = await commands.run(sdk.dart, [tool, '--help']);
    require(
        [
          'extract-surface',
          'merge-interface',
          'resolve-interface-hints',
          'trim-interface'
        ].every(usage.contains),
        'TOOLS_VERSION_UNSUPPORTED',
        'Cached tool lacks WP-3. Run doctor --refresh-tools after updated tools are published.');
    final staging = temporaryName(p.absolute(request.output));
    await Directory(staging).create(recursive: true);
    Future<void> call(List<String> args) async {
      await commands.run(sdk.dart, [tool, ...args],
          code: 'INTERFACE_GENERATION_FAILED');
    }

    String file(String name) => p.join(staging, name);
    final platform = environment.sdkInput(sdk, managed,
        'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill');
    final frontend = environment.sdkInput(sdk, managed,
        'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot');
    final index = file('module-index.dill');
    final indexEntry = file('index-entry.dart');
    await File(indexEntry).writeAsString(
        'import ${jsonEncode(Uri.file(p.absolute(request.module)).toString())};\nvoid main() {}\n');
    // Source compilation is only for inspecting module imports. The tool dill is from CI.
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
          p.absolute(request.packages),
          '--output-dill',
          index,
          indexEntry
        ],
        code: 'INTERFACE_INDEX_FAILED');
    await call([
      'extract-surface',
      '--dill',
      p.absolute(request.dill),
      '--own',
      request.own.join(','),
      '--out-iface',
      file('referenced.yaml'),
      '--out-trim-iface',
      file('referenced-trim.yaml')
    ]);
    final history = <Map<String, dynamic>>[];
    String? additions;
    var input = file('referenced.yaml'),
        trimInput = file('referenced-trim.yaml');
    String? previousHash;
    for (var round = 1; round <= request.maxRounds; round++) {
      final iface = file('round-$round.yaml'),
          trim = file('round-$round-trim.yaml');
      await call([
        'merge-interface',
        '--dill',
        p.join(yamlCache, 'probe/linked.dill'),
        '--iface',
        input,
        '--trim-iface',
        trimInput,
        '--protocol',
        p.join(yamlCache, 'protocol_interface-${sdk.version}.yaml'),
        '--mode',
        request.mode,
        if (request.mode == 'whole') ...[
          '--platform-privates',
          p.join(yamlCache, 'platform_privates-${sdk.version}.yaml')
        ],
        if (additions != null) ...['--additions', additions],
        '--out-iface',
        iface,
        '--out-trim-iface',
        trim
      ]);
      final digest = await hashFile(iface);
      require(digest != previousHash, 'INTERFACE_NO_PROGRESS',
          'Compiler hints made no progress in round $round. Evidence: $staging');
      previousHash = digest;
      final bytecode = file('round-$round.bytecode');
      var validationPlatform = platform;
      String? imported;
      if (request.mode == 'lean') {
        imported = file('round-$round-host.dill');
        validationPlatform = file('round-$round-platform.dill');
        await call([
          'trim-interface',
          '--dill',
          p.absolute(request.dill),
          '--platform',
          platform,
          '--trim-iface',
          trim,
          '--out',
          imported,
          '--out-platform',
          validationPlatform
        ]);
      }
      final compilerArgs = [
        'bytecode',
        '--platform',
        validationPlatform,
        if (imported != null) ...['--import-dill', imported],
        '--target',
        'flutter',
        '--packages',
        p.absolute(request.packages),
        '--validate',
        iface,
        '--aot-only',
        '--prefix-library-uris',
        'wp3_validation',
        if (request.mode == 'whole') ...[
          '--allow-dynamic-calls-in-dynamic-modules',
          '--extra-selectors-allowed-in-dynamic-calls=${wholeSelectors.join(',')}'
        ],
        '-o',
        bytecode,
        p.absolute(request.module)
      ];
      final result = await commands.runResult(sdk.dart, [tool, ...compilerArgs],
          code: 'INTERFACE_VALIDATION_FAILED');
      final log = file('round-$round.log');
      await File(log).writeAsString('${result.stderr}\n${result.stdout}');
      history.add({
        'round': round,
        'interface_sha256': digest,
        'exit_code': result.exitCode,
        'diagnostic': p.basename(log)
      });
      if (result.exitCode == 0) {
        require(
            await File(bytecode).exists() && await File(bytecode).length() > 0,
            'INTERFACE_VALIDATION_FAILED',
            'Validator succeeded without bytecode output.');
        await File(iface).copy(file('dynamic_interface.yaml'));
        await File(trim).copy(file('trim_interface.yaml'));
        final report = <String, dynamic>{
          'status': 'interface_validated',
          ...sdk.toJson(),
          'mode': request.mode,
          'rounds': history,
          'tool_sha256': await hashFile(tool),
          'input_dill_sha256': await hashFile(request.dill),
          'module_sha256': await hashFile(request.module),
          'own': request.own,
          'dynamic_interface_sha256': digest,
          'trim_interface_sha256': await hashFile(trim),
          'dynamic_selectors':
              request.mode == 'whole' ? wholeSelectors : <String>[],
          'host_build_verified': false,
          'device_verified': false
        };
        await writeObject(file('interface.manifest.json'), report);
        await Directory(staging).rename(p.absolute(request.output));
        return {...report, 'output': p.absolute(request.output)};
      }
      await writeObject(file('validation-history.json'), {'rounds': history});
      require(round < request.maxRounds, 'INTERFACE_NOT_CONVERGED',
          'Validation did not converge after $round rounds. Evidence: $staging');
      additions = file('round-$round-additions.yaml');
      await call([
        'resolve-interface-hints',
        '--dill',
        index,
        '--own',
        request.own.join(','),
        '--log',
        log,
        '--out',
        additions
      ]);
      input = iface;
      trimInput = trim;
    }
    throw Failure(
        'INTERFACE_NOT_CONVERGED', 'No validated interface was produced.');
  }
}
