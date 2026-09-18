import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/android.dart';
import 'package:flutter_patcher_cli/src/sdk/host.dart';

void main() {
  test('build-tools versions sort numerically with rc before release', () {
    final versions = ['9.0.0', '34.0.0', '35.0.0-rc1', '35.0.0', '33.0.2'];
    versions.sort(compareBuildToolsVersions);
    expect(versions, ['9.0.0', '33.0.2', '34.0.0', '35.0.0-rc1', '35.0.0']);
  });

  test('SDK lookup prefers ANDROID_HOME, then the host default location',
      () async {
    final temp = await Directory.systemTemp.createTemp('android-sdk-');
    addTearDown(() => temp.delete(recursive: true));
    final explicit = p.join(temp.path, 'explicit');
    final local = p.join(temp.path, 'local');
    for (final root in [explicit, local]) {
      await Directory(p.join(root, 'build-tools')).create(recursive: true);
    }
    const windows = HostIdentity('windows', 'x64');
    expect(
        locateAndroidSdk(windows,
            environment: {'ANDROID_HOME': explicit, 'LOCALAPPDATA': local}),
        explicit);
    expect(locateAndroidSdk(windows, environment: {'LOCALAPPDATA': temp.path}),
        isNull);
    await Directory(p.join(temp.path, 'Android', 'Sdk', 'build-tools'))
        .create(recursive: true);
    expect(locateAndroidSdk(windows, environment: {'LOCALAPPDATA': temp.path}),
        p.join(temp.path, 'Android', 'Sdk'));
    // Linux looks under ~/Android/Sdk; a HOME without one yields nothing.
    expect(
        locateAndroidSdk(const HostIdentity('linux', 'x64'),
            environment: {'HOME': explicit}),
        isNull);
    expect(
        locateAndroidSdk(const HostIdentity('linux', 'x64'),
            environment: {'HOME': temp.path}),
        p.join(temp.path, 'Android', 'Sdk'));
    expect(
        locateAndroidSdk(windows,
            environment: {'ANDROID_HOME': p.join(temp.path, 'missing')}),
        isNull);
  });

  test('aapt comes from the newest build-tools that ships it', () async {
    final temp = await Directory.systemTemp.createTemp('android-aapt-');
    addTearDown(() => temp.delete(recursive: true));
    const host = HostIdentity('linux', 'x64');
    for (final version in ['9.0.0', '34.0.0', '35.0.0']) {
      final dir = Directory(p.join(temp.path, 'build-tools', version));
      await dir.create(recursive: true);
      if (version != '35.0.0') {
        await File(p.join(dir.path, 'aapt')).writeAsString('');
      }
    }
    expect(await selectAapt(temp.path, host),
        p.join(temp.path, 'build-tools', '34.0.0', 'aapt'));
    await Directory(p.join(temp.path, 'build-tools')).delete(recursive: true);
    await Directory(p.join(temp.path, 'build-tools', 'x'))
        .create(recursive: true);
    await expectLater(
        selectAapt(temp.path, host),
        throwsA(isA<Failure>()
            .having((e) => e.code, 'code', 'ANDROID_SDK_MISSING')));
  });

  test('JAVA_HOME is only validated when set', () async {
    final temp = await Directory.systemTemp.createTemp('java-home-');
    addTearDown(() => temp.delete(recursive: true));
    const host = HostIdentity('windows', 'x64');
    checkJavaHome(host, environment: const {});
    expect(
        () => checkJavaHome(host, environment: {'JAVA_HOME': temp.path}),
        throwsA(
            isA<Failure>().having((e) => e.code, 'code', 'JAVA_HOME_INVALID')));
    await File(p.join(temp.path, 'bin', 'java.exe')).create(recursive: true);
    checkJavaHome(host, environment: {'JAVA_HOME': temp.path});
  });
}
