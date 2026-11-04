import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/sdk/artifacts.dart';
import 'package:flutter_patcher/src/cli/sdk/environment.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';

/// Records git invocations and stops `prepare` at the first one.
class GitRecorder extends Commands {
  final calls = <List<String>>[];
  GitRecorder(super.cache);
  @override
  Future<String> run(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
  }) async {
    calls.add(args);
    throw Failure('STOP', 'recorded');
  }

  @override
  Future<CommandResult> runResult(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
    String? logPath,
  }) async {
    calls.add(args);
    throw Failure('STOP', 'recorded');
  }
}

void main() {
  const windows = HostIdentity('windows', 'x64');
  late Directory temp;
  setUp(
    () async =>
        temp = await Directory.systemTemp.createTemp('managed-sdk-eol-'),
  );
  tearDown(() => temp.delete(recursive: true));

  ArtifactStore store() => ArtifactStore(
    temp.path,
    Uri.parse('file:///unused/'),
    Uri.parse('file:///unused'),
    Downloads(offline: true),
  );

  SdkIdentity sdk(HostIdentity host) => SdkIdentity(
    temp.path,
    '3.47.2',
    'e' * 40,
    '3.13.2',
    'f' * 40,
    host: host,
  );

  Future<List<String>> clone(HostIdentity host) async {
    final commands = GitRecorder(temp.path);
    await expectLater(
      EnvironmentBuilder(
        p.join(temp.path, 'cache'),
        commands,
      ).prepare(sdk(host), store()),
      throwsA(isA<Failure>().having((f) => f.code, 'code', 'STOP')),
    );
    return commands.calls.single;
  }

  test(
    'the managed SDK is cloned from the selected SDK when it can be',
    () async {
      // The selected SDK is a git checkout holding the version's tag.
      Future<String> git(List<String> args) async {
        final result = await Process.run('git', [
          '-C',
          temp.path,
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          ...args,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return (result.stdout as String).trim();
      }

      await git(['init', '-q']);
      File(p.join(temp.path, 'README')).writeAsStringSync('sdk');
      await git(['add', 'README']);
      await git(['commit', '-q', '-m', 'sdk']);
      await git(['tag', '3.47.2']);
      final head = await git(['rev-parse', 'HEAD']);
      final commands = GitRecorder(temp.path);
      await expectLater(
        EnvironmentBuilder(p.join(temp.path, 'cache'), commands).prepare(
          SdkIdentity(
            temp.path,
            '3.47.2',
            'e' * 40,
            '3.13.2',
            head,
            host: HostIdentity.linuxX64,
          ),
          store(),
        ),
        throwsA(isA<Failure>().having((f) => f.code, 'code', 'STOP')),
      );
      expect(
        commands.calls.single,
        contains(Uri.directory(temp.path).toString()),
      );
      expect(commands.calls.single, isNot(contains(contains('github.com'))));
    },
  );

  test('Windows clones the managed SDK with LF line endings', () async {
    final args = await clone(windows);
    final at = args.indexOf('clone');
    expect(args.sublist(at + 1, at + 5), [
      '--config',
      'core.autocrlf=false',
      '--config',
      'core.eol=lf',
    ]);
  });

  test('Linux clone arguments are unchanged', () async {
    final args = await clone(HostIdentity.linuxX64);
    expect(args.where((a) => a.startsWith('core.')), isEmpty);
  });

  test('a Windows SDK cached before the LF pin is prepared again', () async {
    final marker = File(
      p.join(temp.path, 'cache/flutter/3.47.2/.flutter-patcher-sdk.json'),
    );
    await marker.parent.create(recursive: true);
    Future<String?> failure(Map<String, dynamic> state) async {
      await marker.writeAsString(jsonEncode(state));
      try {
        await EnvironmentBuilder(
          p.join(temp.path, 'cache'),
          GitRecorder(temp.path),
          offline: true,
        ).prepare(sdk(windows), store());
      } on Failure catch (f) {
        return f.code;
      }
      return null;
    }

    expect(await failure(sdk(windows).toJson()), 'SDK_NOT_READY');
    expect(
      await failure({...sdk(windows).toJson(), 'checkout_eol': 'lf'}),
      'STOP',
    );
  });
}
