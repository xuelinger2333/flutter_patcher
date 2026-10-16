import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/artifacts.dart';
import 'package:flutter_patcher_cli/src/sdk/environment.dart';
import 'package:flutter_patcher_cli/src/sdk/host.dart';

/// Records git invocations and stops `prepare` at the first one.
class GitRecorder extends Commands {
  final calls = <List<String>>[];
  GitRecorder(super.cache);
  @override
  Future<String> run(String executable, List<String> args,
      {String? cwd,
      List<int>? inputBytes,
      String code = 'TOOL_FAILED',
      Duration timeout = const Duration(minutes: 15),
      Map<String, String>? extraEnvironment}) async {
    calls.add(args);
    throw Failure('STOP', 'recorded');
  }
}

void main() {
  const windows = HostIdentity('windows', 'x64');
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('wp26-eol-'));
  tearDown(() => temp.delete(recursive: true));

  ArtifactStore store() => ArtifactStore(
      temp.path,
      Uri.parse('file:///unused/'),
      Uri.parse('file:///unused'),
      Downloads(offline: true));

  SdkIdentity sdk(HostIdentity host) =>
      SdkIdentity(temp.path, '3.47.2', 'e' * 40, '3.13.2', 'f' * 40,
          host: host);

  Future<List<String>> clone(HostIdentity host) async {
    final commands = GitRecorder(temp.path);
    await expectLater(
        EnvironmentBuilder(p.join(temp.path, 'cache'), commands)
            .prepare(sdk(host), store(), {}),
        throwsA(isA<Failure>().having((f) => f.code, 'code', 'STOP')));
    return commands.calls.single;
  }

  test('Windows clones the managed SDK with LF line endings', () async {
    final args = await clone(windows);
    final at = args.indexOf('clone');
    expect(args.sublist(at + 1, at + 5),
        ['--config', 'core.autocrlf=false', '--config', 'core.eol=lf']);
  });

  test('Linux clone arguments are unchanged', () async {
    final args = await clone(HostIdentity.linuxX64);
    expect(args.where((a) => a.startsWith('core.')), isEmpty);
  });

  test('a Windows SDK cached before the LF pin is prepared again', () async {
    final marker = File(
        p.join(temp.path, 'cache/flutter/3.47.2/.flutter-patcher-sdk.json'));
    await marker.parent.create(recursive: true);
    Future<String?> failure(Map<String, dynamic> state) async {
      await marker.writeAsString(jsonEncode(state));
      try {
        await EnvironmentBuilder(
                p.join(temp.path, 'cache'), GitRecorder(temp.path),
                offline: true)
            .prepare(sdk(windows), store(), {});
      } on Failure catch (f) {
        return f.code;
      }
      return null;
    }

    expect(await failure(sdk(windows).toJson()), 'SDK_NOT_READY');
    expect(await failure({...sdk(windows).toJson(), 'checkout_eol': 'lf'}),
        'STOP');
  });
}
