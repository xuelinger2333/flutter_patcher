"""Two independently runnable M1 stages. The handoff contains no build cache.

build runs on host A; patch runs on host B using its own checkout/SDK/cache.
Only the dedicated test project, public receipt and baseline store are shared.
"""
import argparse
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import socket
import subprocess
import zipfile


def call(args, cwd, log):
    with log.open('w') as stream:
        result = subprocess.run([str(v) for v in args], cwd=cwd, stdout=stream,
                                stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed; see {log}')


def configure_android(project):
    """Bound only our generated fixtures; isolated runs must not accumulate 8G daemons."""
    file = project / 'android/gradle.properties'
    settings = {'org.gradle.jvmargs': '-Xmx2G -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m',
                'org.gradle.workers.max': '2', 'org.gradle.daemon': 'false',
                'kotlin.compiler.execution.strategy': 'in-process'}
    lines = [line for line in file.read_text().splitlines() if line.partition('=')[0] not in settings]
    file.write_text('\n'.join(lines + [key + '=' + value for key, value in settings.items()]) + '\n')


def execute(stage, flutter, repo, out, artifacts_url, support_url, baseline_store,
            handoff=None, custom_binding=False):
    out.mkdir(parents=True, exist_ok=False)
    dart = flutter / 'bin/cache/dart-sdk/bin/dart'
    cli = repo / 'flutter_patcher_cli/bin/flutter_patcher.dart'
    cache = out / 'cache'
    common = ['--flutter-sdk', flutter, '--cache-dir', cache,
              '--artifacts-url', artifacts_url, '--supported-versions-url', support_url]
    # Public RFC8032 fixture key. Never read or copy a developer's production key.
    seed = out / 'TEST_ONLY_seed.base64'
    public = out / 'TEST_ONLY_public.base64'
    seed.write_text(base64.b64encode(bytes.fromhex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')).decode())
    public.write_text(base64.b64encode(bytes.fromhex(
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode())
    project = out / 'app'
    call([flutter / 'bin/flutter', 'create', '--platforms', 'android', '--org', 'com.example',
          '--project-name', 'wp9_acceptance', project], repo, out / 'create.log')
    configure_android(project)
    dependencies = {'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': str(repo)}}
    specification = {'name': 'wp9_acceptance', 'version': '1.0.0+1',
        'environment': {'sdk': '>=3.13.0 <4.0.0'}, 'dependencies': dependencies,
        'flutter': {'uses-material-design': True, 'assets': ['assets/message.txt']}}
    source = (repo / 'test/acceptance/app/main.dart').read_text()
    source = re.sub(r'  if \(customBinding\) \{.*?\n  \} else \{.*?\n  \}',
                    '  AcceptanceBinding();' if custom_binding else
                    '  WidgetsFlutterBinding.ensureInitialized();', source, count=1, flags=re.S)
    if not custom_binding:
        source = source.replace('class AcceptanceBinding extends WidgetsFlutterBinding {}', '')
        source = source.replace('WidgetsBinding.instance is AcceptanceBinding', 'false')
    (project / 'lib/main.dart').write_text(source)
    (project / 'assets').mkdir()
    (project / 'assets/message.txt').write_text('original')
    # Only our newly created fixture is modified; never an existing user project.
    manifest = project / 'android/app/src/main/AndroidManifest.xml'
    manifest.write_text(manifest.read_text().replace('<application',
        '<uses-permission android:name="android.permission.INTERNET"/>\n<application android:usesCleartextTraffic="true"', 1))
    (project / 'pubspec.yaml').write_text(json.dumps(specification, indent=2))
    call([flutter / 'bin/flutter', 'pub', 'get'], project, out / 'pub.log')
    call([dart, 'pub', 'get'], repo / 'flutter_patcher_cli', out / 'cli-pub.log')
    call([dart, cli, 'doctor', *common, '--json'], repo, out / 'doctor.log')
    report = {'schema': 1, 'stage': stage, 'host': socket.gethostname(),
              'machine_id': Path('/etc/machine-id').read_text().strip(),
              'code_commit': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
              'sdk': json.loads(subprocess.check_output([str(flutter / 'bin/flutter'), '--version', '--machine'], text=True)),
              'device_verified': False, 'custom_binding': custom_binding}
    if stage == 'build':
        call([dart, cli, 'build', 'android', '--strategy', 'bytecode', *common,
              '--project', project, '--baseline-store', baseline_store, '--public-key', public,
              '--version-code', '1', '--out', out / 'release'], repo, out / 'build.log')
        built = json.loads((out / 'release/build.json').read_text())
        if built['status'] != 'build_archived' or not built['runtime_bootstrap']:
            raise AssertionError('Formal archived bootstrap build required')
        report.update(fingerprint=built['fingerprint'], build=built)
        # Matched ordinary-build control, same SDK/project/ABI. No patcher bootstrap.
        call([flutter / 'bin/flutter', 'build', 'apk', '--release', '--target-platform', 'android-arm64'],
             project, out / 'ordinary-build.log')
        normal = project / 'build/app/outputs/flutter-apk/app-release.apk'
        shutil.copyfile(normal, out / 'ordinary.apk')
        sizes = {}
        for label, apk in [('ordinary', normal), ('patcher', out / 'release/app-release.apk')]:
            with zipfile.ZipFile(apk) as z:
                data = z.read('lib/arm64-v8a/libapp.so')
            sizes[label] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        sizes['increment_bytes'] = sizes['patcher']['bytes'] - sizes['ordinary']['bytes']
        sizes['threshold_bytes'] = None
        sizes['status'] = 'threshold_pending_review'
        report['size'] = sizes
        (project / 'lib/main.dart').write_text(source.replace("const revision = 'original';", "const revision = 'so';"))
        call([flutter / 'bin/flutter', 'build', 'apk', '--release', '--target-platform', 'android-arm64'],
             project, out / 'legacy-build.log')
        with zipfile.ZipFile(normal) as z:
            (out / 'legacy-libapp.so').write_bytes(z.read('lib/arm64-v8a/libapp.so'))
    else:
        prior = json.loads(handoff.read_text())
        if prior['sdk']['frameworkVersion'] != report['sdk']['frameworkVersion']:
            raise ValueError('Cross-host SDK version differs')
        if prior['code_commit'] != report['code_commit'] or prior['custom_binding'] != custom_binding:
            raise ValueError('Cross-host code revision or binding fixture differs')
        for key in ['engineRevision', 'dartSdkVersion']:
            if prior['sdk'][key] != report['sdk'][key]:
                raise ValueError('Cross-host SDK identity differs: ' + key)
        report['independent_machine'] = prior['machine_id'] != report['machine_id']
        report['fingerprint'] = prior['fingerprint']
        for tier, seq in [('lean', 7), ('whole', 8)]:
            main = source.replace("const revision = 'original';", f"const revision = '{tier}';")
            # Embed the const value: a new SDK Icons getter is intentionally not
            # callable from a lean module's baseline dynamic interface.
            icon = "IconData(0xe57f, fontFamily: 'MaterialIcons')" if tier == 'lean' else "IconData(0xe25b, fontFamily: 'MaterialIcons')"
            main = main.replace('Icons.home', icon)
            if tier == 'whole':
                extra = out / 'extra'
                (extra / 'lib').mkdir(parents=True)
                (extra / 'pubspec.yaml').write_text('name: wp9_extra\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n')
                (extra / 'lib/extra.dart').write_text("String message() => 'whole';\n")
                dependencies['wp9_extra'] = {'path': str(extra)}
                main = "import 'package:wp9_extra/extra.dart' as extra;\n" + main.replace(
                    "const revision = 'whole';", 'final revision = extra.message();')
            (project / 'lib/main.dart').write_text(main)
            (project / 'assets/message.txt').write_text(tier)
            (project / 'pubspec.yaml').write_text(json.dumps(specification, indent=2))
            call([flutter / 'bin/flutter', 'pub', 'get'], project, out / f'{tier}-pub.log')
            call([dart, cli, 'patch', 'android', '--strategy', 'bytecode', *common,
                  '--project', project, '--fingerprint', prior['fingerprint'], '--seq', str(seq),
                  '--version-code', '1', '--baseline-store', baseline_store, '--private-key', seed,
                  '--out', out / tier], repo, out / f'{tier}-patch.log')
            patch = json.loads((out / tier / 'patch.json').read_text())
            expected_tier = 'whole' if custom_binding else tier
            if patch['status'] != 'patch_created' or patch['tier'] != expected_tier:
                raise AssertionError(patch)
            call([dart, cli, 'publish', '--out', out / 'mock', '--patch', out / tier / 'patch.fptc',
                  '--version-code', '1'], repo, out / f'{tier}-publish.log')
            report[tier] = patch
        call([dart, cli, 'publish', '--action', 'withdraw', '--out', out / 'mock'], repo, out / 'withdraw.log')
    (out / 'handoff.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=['build', 'patch'], required=True)
    for name in ['flutter', 'repo', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--handoff', type=Path)
    for name in ['artifacts-url', 'support-url', 'baseline-store']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--custom-binding', action='store_true')
    execute(**vars(parser.parse_args()))
