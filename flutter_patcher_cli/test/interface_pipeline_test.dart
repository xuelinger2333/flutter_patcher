import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/artifacts.dart';
import 'package:flutter_patcher_cli/src/sdk/environment.dart';
import 'package:flutter_patcher_cli/src/interfaces/pipeline.dart';

class CompilerFixture extends Commands {
  var validations = 0, merges = 0;
  bool stuck = false, neverPass = false, oldTool = false;
  final invocations = <List<String>>[];
  CompilerFixture(super.cache);
  Future<void> write(String file, String value) async {
    await File(file).parent.create(recursive: true);
    await File(file).writeAsString(value);
  }

  String value(List<String> args, String option) =>
      args[args.indexOf(option) + 1];
  @override
  Future<String> run(String executable, List<String> args,
      {String? cwd,
      String code = 'TOOL_FAILED',
      Duration timeout = const Duration(minutes: 15),
      Map<String, String>? extraEnvironment}) async {
    invocations.add(args);
    if (args.last == '--help') {
      return oldTool
          ? 'bytecode'
          : 'extract-surface merge-interface resolve-interface-hints trim-interface';
    }
    if (args.contains('--output-dill')) {
      await write(value(args, '--output-dill'), 'index');
    } else if (args.contains('extract-surface') ||
        args.contains('merge-interface')) {
      if (args.contains('merge-interface')) merges++;
      await write(value(args, '--out-iface'),
          jsonEncode({'round': stuck ? 0 : merges}));
      await write(value(args, '--out-trim-iface'), 'trim-$merges');
    } else if (args.contains('resolve-interface-hints')) {
      await write(value(args, '--out'), '{}');
    }
    return '{}';
  }

  @override
  Future<CommandResult> runResult(String executable, List<String> args,
      {String? cwd,
      String code = 'TOOL_FAILED',
      Duration timeout = const Duration(minutes: 15),
      Map<String, String>? extraEnvironment}) async {
    invocations.add(args);
    validations++;
    if (validations == 1 || neverPass) {
      return CommandResult(1, '', "list class 'Extra' as callable");
    }
    await write(value(args, '-o'), 'validated-bytecode');
    return CommandResult(0, '', '');
  }
}

void main() {
  late Directory root;
  late CompilerFixture compiler;
  late InterfacePipeline pipeline;
  late InterfaceRequest request;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('wp3-pipeline-');
    compiler = CompilerFixture(root.path);
    for (final name in [
      'app.dill',
      'module.dart',
      'packages.json',
      'tools.dill'
    ]) {
      await File(p.join(root.path, name)).writeAsString('fixture');
    }
    final sdk = SdkIdentity(
        p.join(root.path, 'sdk'), '3.47.2', 'a' * 40, '3.13.2', 'b' * 40);
    pipeline = InterfacePipeline(compiler, sdk, p.join(root.path, 'tools.dill'),
        root.path, root.path, EnvironmentBuilder(root.path, compiler));
    request = InterfaceRequest(
        dill: p.join(root.path, 'app.dill'),
        module: p.join(root.path, 'module.dart'),
        packages: p.join(root.path, 'packages.json'),
        output: p.join(root.path, 'result'),
        own: ['own']);
  });
  tearDown(() => root.delete(recursive: true));
  test('validation converges and commits outputs only after success', () async {
    final result = await pipeline.generate(request);
    expect(compiler.validations, 2);
    expect(result['host_build_verified'], false);
    expect(result['device_verified'], false);
    expect(
        await File(p.join(request.output, 'dynamic_interface.yaml')).exists(),
        true);
    expect(await File(request.dill).readAsString(), 'fixture');
    expect(
        compiler.invocations
            .any((args) => args.contains('resolve-interface-hints')),
        true);
    expect(compiler.invocations.any((args) => args.contains('trim-interface')),
        true);
    expect(compiler.invocations.firstWhere((args) => args.contains('bytecode')),
        contains('--import-dill'));
  });
  test('unchanged interface stops instead of looping', () async {
    compiler.stuck = true;
    await expectLater(
        pipeline.generate(request),
        throwsA(isA<Failure>()
            .having((e) => e.code, 'code', 'INTERFACE_NO_PROGRESS')));
    expect(compiler.validations, 1);
    expect(Directory(request.output).existsSync(), false);
  });
  test('round limit fails without promoting partial outputs', () async {
    compiler.neverPass = true;
    await expectLater(
        pipeline.generate(request),
        throwsA(isA<Failure>()
            .having((e) => e.code, 'code', 'INTERFACE_NOT_CONVERGED')));
    expect(compiler.validations, 5);
    expect(Directory(request.output).existsSync(), false);
  });
  test('old tool fails with refresh instruction before preparing outputs',
      () async {
    compiler.oldTool = true;
    await expectLater(
        pipeline.generate(request),
        throwsA(isA<Failure>()
            .having((e) => e.code, 'code', 'TOOLS_VERSION_UNSUPPORTED')));
    expect(compiler.merges, 0);
    expect(Directory(request.output).existsSync(), false);
  });
  test('existing output is preserved', () async {
    await Directory(request.output).create();
    await File(p.join(request.output, 'keep')).writeAsString('original');
    await expectLater(pipeline.generate(request), throwsA(isA<Failure>()));
    expect(
        await File(p.join(request.output, 'keep')).readAsString(), 'original');
  });
  test('whole mode passes the bounded selector allowlist to compiler',
      () async {
    request = InterfaceRequest(
        dill: request.dill,
        module: request.module,
        packages: request.packages,
        output: request.output,
        own: request.own,
        mode: 'whole');
    await pipeline.generate(request);
    final call =
        compiler.invocations.firstWhere((args) => args.contains('bytecode'));
    expect(call, isNot(contains('--import-dill')));
    expect(call, contains('--allow-dynamic-calls-in-dynamic-modules'));
    expect(
        call,
        contains(
            '--extra-selectors-allowed-in-dynamic-calls=-,+,*,get:index,relativeError,absoluteError'));
  });
}
