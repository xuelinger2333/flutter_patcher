"""Build, patch, publish and verify an authenticated host on a real device.

One command per strategy (`so` or `bytecode`). Keys, the TLS certificate and
the HTTPS origin are generated per run and trusted only by the fixture app;
the phone reaches the origin through `adb reverse`. Requires Python 3, a JDK
(keytool), the Android SDK and an unlocked API 28+ arm64 device.

`--remote HOST` prepares on an SSH build host (e.g. the Linux builder) from a
snapshot of this working tree, fetches the outputs and verifies locally.
"""
import argparse
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import tarfile
import time
import urllib.error
import urllib.request

from integration import WINDOWS, call, configure_android, dart_binary, flutter_launcher, normalize_line_endings, snapshot

PACKAGE = 'com.example.authenticated_device'
CONTROL = 'http://127.0.0.1:8767'
ORIGIN = 'https://localhost:8443'


def tool(directory, name):
    """`name` inside `directory` when given, else from PATH."""
    path = Path(directory) / (name + ('.exe' if WINDOWS else '')) if directory else shutil.which(name)
    if not path or not Path(path).exists():
        raise RuntimeError(f'{name} not found')
    return path


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')


def create_app(flutter, repo, out, ca):
    app = out / 'app'
    call([flutter_launcher(flutter), 'create', '--empty', '--platforms', 'android', '--org', 'com.example',
          '--project-name', 'authenticated_device', app], out, out / 'create.log')
    configure_android(app)
    res = app / 'android/app/src/main/res'
    (res / 'raw').mkdir(exist_ok=True)
    shutil.copy(ca, res / 'raw/test_ca.pem')
    write(res / 'xml/network_security_config.xml',
          '<network-security-config>\n  <base-config cleartextTrafficPermitted="false">\n'
          '    <trust-anchors>\n      <certificates src="system"/>\n'
          '      <certificates src="@raw/test_ca"/>\n    </trust-anchors>\n'
          '  </base-config>\n</network-security-config>\n')
    manifest = app / 'android/app/src/main/AndroidManifest.xml'
    write(manifest, manifest.read_text().replace('<application', '<uses-permission android:name='
          '"android.permission.INTERNET"/>\n    <application android:networkSecurityConfig='
          '"@xml/network_security_config"', 1))
    write(app / 'pubspec.yaml', json.dumps(dict(
        name='authenticated_device', version='1.0.0+1', environment={'sdk': '>=3.8.0 <4.0.0'},
        dependencies={'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': repo.as_posix()}},
        flutter={'assets': ['assets/msg.txt']})))
    write(app / 'assets/msg.txt', 'asset-original')
    source = (repo / 'test/acceptance/app/authenticated_device.dart').read_text(encoding='utf-8')
    source = source.replace('__TEST_CA__', ca.read_text().strip())
    write(app / 'lib/main.dart', source)
    normalize_line_endings(app)
    call([flutter_launcher(flutter), 'pub', 'get'], app, out / 'pub.log')
    return app, source


def prepare(args, repo, out):
    dart, cli = dart_binary(args.flutter_sdk), repo / 'bin/flutter_patcher.dart'
    common = ['--flutter-sdk', args.flutter_sdk]

    def patcher(name, *argv):
        print('STAGE ' + name, flush=True)
        call([dart, cli, *argv], repo, out / (name + '.log'))

    call([flutter_launcher(args.flutter_sdk), 'pub', 'get'], repo, out / 'cli-pub.log')
    keys = {}
    for role in ['patch', 'publisher', 'root']:
        patcher('keys-' + role, 'keys', 'init', '--out', out / 'keys' / role)
        keys[role] = (out / 'keys' / role / 'public-key.base64').read_text().strip()
    tls, password = out / 'tls', secrets.token_hex(16)
    tls.mkdir()
    keytool = tool(args.java_home and Path(args.java_home) / 'bin', 'keytool')
    call([keytool, '-genkeypair', '-alias', 'tls', '-keyalg', 'EC', '-groupname', 'secp256r1',
          '-dname', 'CN=localhost', '-ext', 'SAN=dns:localhost', '-validity', '7', '-storetype', 'PKCS12',
          '-keystore', tls / 'tls.p12', '-storepass', password], out, out / 'keytool.log')
    call([keytool, '-exportcert', '-rfc', '-alias', 'tls', '-keystore', tls / 'tls.p12',
          '-storepass', password, '-file', tls / 'test_ca.pem'], out, out / 'keytool-export.log')
    write(tls / 'password.txt', password)
    app, source = create_app(args.flutter_sdk, repo, out, tls / 'test_ca.pem')

    policy = dict(schema='1', application_id=PACKAGE, version_code='1', channel='device', flavor='default',
                  abi='arm64-v8a', strategy=args.strategy, fptc_key=keys['patch'], root_key=keys['root'],
                  keys='release:' + keys['publisher'])
    write(out / 'host-policy.json', json.dumps(policy, sort_keys=True, separators=(',', ':')))
    store = (out / 'store').as_uri()
    (out / 'store').mkdir()
    patcher('build', 'build', 'android', *common, '--project', app, '--baseline-store', store,
            '--public-key', out / 'keys/patch/public-key.base64', '--host-policy', out / 'host-policy.json',
            '--version-code', '1', '--out', out / 'release')
    built = json.loads((out / 'release/build.json').read_text())

    if args.strategy == 'so':  # Bytecode patches replace Dart code only.
        write(app / 'assets/msg.txt', 'asset-patched')
    for seq, revision, crash in [(1, 'patched', False), (2, 'crash', True), (3, 'patched-3', False)]:
        main = source.replace("const revision = 'original';", f"const revision = '{revision}';")
        write(app / 'lib/main.dart', main.replace('const crash = false;', f'const crash = {str(crash).lower()};'))
        patcher(f'patch{seq}', 'patch', 'android', *common, '--project', app, '--fingerprint',
                built['fingerprint'], '--seq', str(seq), '--version-code', '1', '--baseline-store', store,
                '--private-key', out / 'keys/patch/private-key.base64', '--out', out / f'patch{seq}')

    srv = out / 'srv'
    version = next(line.split(':', 1)[1].strip() for line in (repo / 'pubspec.yaml').read_text().splitlines()
                   if line.startswith('version:'))
    for revision, extra in enumerate([dict(action='publish', patch_seq='1'), dict(action='publish', patch_seq='2'),
                                      dict(action='publish', patch_seq='3'),
                                      dict(action='withdraw', withdraw_through_seq='3')], 1):
        operation = secrets.token_hex(16)
        request = dict(application_id=PACKAGE, store=(srv / 'pub').as_uri(), operation=operation,
                       fields=dict(schema='1', key_id='release', application_id=PACKAGE, channel='device',
                                   flavor='default', version_code='1', abi='arm64-v8a',
                                   fingerprint=built['fingerprint'], strategy=args.strategy,
                                   minPluginVersion=version, revision=str(revision), **extra),
                       baseline_store=store, expected_revision=revision - 1,
                       private_key=str(out / 'keys/publisher/private-key.base64'),
                       public_key=str(out / 'keys/publisher/public-key.base64'), created_at=int(time.time()))
        if extra['action'] == 'publish':
            request.update(patch=str(out / f'patch{extra["patch_seq"]}/patch.fptc'), public_base_url=ORIGIN + '/pub')
        write(out / f'publish{revision}.json', json.dumps(request, indent=2))
        patcher(f'publish{revision}', 'publish', '--production', '--commit', '--request', out / f'publish{revision}.json')
        write(srv / f'manifest{revision}.json',
              json.loads((srv / 'pub/catalog.json').read_text())['releases'][operation]['wire'])
    write(srv / 'tampered.json', tamper((srv / 'manifest1.json').read_text()))


def remote_prepare(args, repo, out):
    """Run --prepare-only on `args.remote` from a source snapshot; fetch what verify needs."""
    root = f'{args.remote_root}/{out.name}'
    ssh = lambda command: subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=30',
                                          args.remote, command], check=True)
    snapshot(repo, out)
    ssh(shlex.join(['mkdir', '-p', root]))
    subprocess.run(['scp', '-q', str(out / 'source.tar.gz'), f'{args.remote}:{root}/'], check=True)
    print(f'STAGE remote-prepare {args.remote}:{root}', flush=True)
    prepare = shlex.join(['python3', 'source/test/acceptance/authenticated_device.py', '--prepare-only',
                          '--strategy', args.strategy, '--flutter-sdk', args.remote_flutter, '--out', 'out'])
    # Keys and the baseline store stay on the builder; verify needs only the APK, origin and TLS.
    ssh(f'cd {shlex.quote(root)} && tar -xzf source.tar.gz && ANDROID_HOME={shlex.quote(args.remote_android)} '
        f'{prepare} > prepare.log 2>&1; code=$?; tar --exclude=./app --exclude=./store --exclude=./keys '
        f'-czf outputs.tar.gz prepare.log -C out .; exit $code')
    subprocess.run(['scp', '-q', f'{args.remote}:{root}/outputs.tar.gz', str(out)], check=True)
    with tarfile.open(out / 'outputs.tar.gz') as archive:
        archive.extractall(out, filter='data')


def tamper(wire):
    """Flip one signature character, keeping the envelope byte-canonical."""
    signature = json.loads(wire)['signature']
    return wire.replace(signature, ('B' if signature[0] == 'A' else 'A') + signature[1:], 1)


def control(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(CONTROL + path, data=data), timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {'http': e.code, **json.loads(e.read() or b'{}')}


def verify(args, out):
    sdk = os.environ.get('ANDROID_HOME')
    adb = [tool(sdk and Path(sdk) / 'platform-tools', 'adb'), '-s', args.serial]
    run = lambda *a, timeout=180: subprocess.run([*map(str, adb), *a], capture_output=True, encoding='utf-8',
                                                 errors='replace', timeout=timeout)
    srv = out / 'srv'
    server = subprocess.Popen([dart_binary(args.flutter_sdk), Path(__file__).parent / 'tls_server.dart', srv,
                               out / 'tls/tls.p12', (out / 'tls/password.txt').read_text()],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    steps, failed = [], []
    try:
        if server.stdout.readline().strip() != 'READY':
            raise RuntimeError('TLS server did not start')
        run('reverse', 'tcp:8443', 'tcp:8443')
        run('forward', 'tcp:8767', 'tcp:8767')
        run('uninstall', PACKAGE)
        try:
            control('/status')
            raise RuntimeError('Another app on the device already serves port 8767; stop it first')
        except OSError:
            pass
        installed = run('install', '-r', out / 'release/app-release.apk', timeout=600)  # On-device approval.
        if 'Success' not in installed.stdout:
            raise RuntimeError('Install failed: ' + installed.stdout + installed.stderr)
        run('logcat', '-c')

        def launch():
            run('shell', 'am', 'force-stop', PACKAGE)
            time.sleep(2)
            run('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity')
            for _ in range(40):
                time.sleep(0.5)
                try:
                    control('/status')
                    time.sleep(6)  # Let the first frame settle the boot attempt.
                    return control('/status')
                except OSError:
                    pass
            return {'error': 'no status'}

        asset = 'asset-patched' if args.strategy == 'so' else 'asset-original'
        original = dict(revision='original', asset='asset-original', version=None, diagnostic='noPatch')
        patched = dict(revision='patched', asset=asset, version='1', diagnostic='patched')
        check = lambda n: lambda: control('/check', {'url': f'{ORIGIN}/manifest{n}.json'})
        payload = srv / json.loads(base64.b64decode(json.loads((srv / 'manifest1.json').read_text())['payload']))[
            'url'].removeprefix(ORIGIN + '/')
        good = payload.read_bytes()

        def rejected():  # Must fail native verification, not an earlier parse.
            actual = control('/check', {'url': ORIGIN + '/tampered.json'})
            return {**actual, 'native': 'AUTH_UPDATE_REJECTED' in actual.get('error', '')}

        def corrupt():  # The origin serves altered bytes for an authentic manifest.
            payload.write_bytes(good[:-1] + bytes([good[-1] ^ 1]))
            try:
                return check(1)()
            finally:
                payload.write_bytes(good)

        plan = [
            ('original boot', launch, original),
            ('tampered manifest rejected', rejected, {'http': 409, 'native': True}),
            ('corrupt payload rejected', corrupt, {'update': True, 'ok': False}),
            ('retry after corrupt payload', check(1), {'update': True, 'ok': True}),
            ('same manifest is not fresh', check(1), {'update': False}),
            ('patched boot', launch, patched),
            ('patched second boot', launch, patched),
            ('rollback', lambda: control('/rollback', {}), {'ok': True}),
            ('original after rollback', launch, original),
            ('replay after rollback', check(1), {'update': False}),
            ('apply crash patch', check(2), {'update': True, 'ok': True}),
            ('crash patch does not start', lambda: {'crash_started': launch().get('revision') == 'crash'},
             {'crash_started': False}),
            ('crash protection recovers', launch, {**original, 'diagnostic': 'droppedCircuitBreaker'}),
            ('apply next patch', check(3), {'update': True, 'ok': True}),
            ('next patch boots', launch, {**patched, 'revision': 'patched-3', 'version': '3'}),
            ('withdraw', check(4), {'update': True, 'ok': True}),
            ('original after withdraw', launch, original),
        ]
        for name, action, expected in plan:
            actual = action()
            ok = all(actual.get(k) == v for k, v in expected.items())
            steps.append(dict(step=name, passed=ok, actual=actual))
            print(('PASS ' if ok else 'FAIL ') + name + ' ' + json.dumps(actual), flush=True)
            if not ok:
                failed.append(name)
                break
    finally:
        server.kill()
        (out / 'tls-server.log').write_text(server.stdout.read() or '')
        try:  # Best effort: a disconnected device must not hide the real failure.
            (out / 'logcat.txt').write_text(run('logcat', '-d', '-v', 'threadtime').stdout, encoding='utf-8')
        except subprocess.TimeoutExpired:
            pass
    return steps, failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strategy', choices=['so', 'bytecode'], required=True)
    parser.add_argument('--flutter-sdk', type=Path, required=True)
    parser.add_argument('--serial')
    parser.add_argument('--java-home', default=os.environ.get('JAVA_HOME'))
    parser.add_argument('--out', type=Path)
    parser.add_argument('--resume-built', action='store_true',
                        help='Reuse a completed build/patch/publish in --out; rerun device steps only')
    parser.add_argument('--prepare-only', action='store_true', help='Build, patch and publish; skip the device')
    parser.add_argument('--remote', help='SSH host alias that builds, patches and publishes')
    parser.add_argument('--remote-root', default='/root/.flutter_patcher/authenticated')
    parser.add_argument('--remote-flutter', default='/opt/flutter')
    parser.add_argument('--remote-android', default='/opt/android-sdk')
    args = parser.parse_args()
    if not args.prepare_only and not args.serial:
        parser.error('--serial is required unless --prepare-only')
    repo = Path(__file__).resolve().parents[2]
    out = (args.out or repo / '.dart_tool/flutter_patcher/authenticated' /
           f'{args.strategy}-{datetime.now():%Y%m%d-%H%M%S}').resolve()
    if args.resume_built:
        if not (out / 'srv/manifest4.json').exists():
            raise SystemExit('--resume-built needs a prepared --out')
    else:
        out.mkdir(parents=True, exist_ok=False)
        remote_prepare(args, repo, out) if args.remote else prepare(args, repo, out)
        if args.prepare_only:
            print(f'PREPARED {out}')
            return
    steps, failed = verify(args, out)
    result = dict(status='failed' if failed else 'passed', strategy=args.strategy, serial=args.serial,
                  steps=steps, failed=failed)
    write(out / 'result.json', json.dumps(result, indent=2))
    print(f'{result["status"].upper()} {out}')
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()