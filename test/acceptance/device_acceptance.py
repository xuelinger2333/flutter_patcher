"""Build, patch, publish and verify a patchable host on a real device.

One command per strategy (`so` or `bytecode`) and signing (`signed` or
`unsigned`). The patch key, the TLS certificate and the HTTPS origin are
generated per run and trusted only by the fixture app; the phone reaches the
origin through `adb reverse`. Requires Python 3, a JDK (keytool), the Android
SDK and an unlocked API 28+ arm64 device.

`--remote HOST` prepares on an SSH build host (e.g. the Linux builder) from a
snapshot of this working tree, fetches the outputs and verifies locally.
"""
import argparse
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

PACKAGE = 'com.example.device_fixture'
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
          '--project-name', 'device_fixture', app], out, out / 'create.log')
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
        name='device_fixture', version='1.0.0+1', environment={'sdk': '>=3.8.0 <4.0.0'},
        dependencies={'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': repo.as_posix()},
                      'fixture_support': {'path': (repo / 'test/acceptance/app/fixture_support').as_posix()}},
        flutter={'assets': ['assets/msg.txt']})))
    write(app / 'assets/msg.txt', 'asset-original')
    source = (repo / 'test/acceptance/app/device_fixture.dart').read_text(encoding='utf-8')
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
    srv = out / 'srv'
    (srv / 'pub').mkdir(parents=True)
    config = f"store: '{(srv / 'pub').as_uri()}/'\nbaseline_store: '{(out / 'store').as_uri()}/'\n"
    key = []
    if args.signing == 'signed':
        # One key bundle file signs everything, as a CI job's would.
        patcher('keys', 'keys', 'init', '--out', out / 'keys.json')
        public = next(json.loads(line) for line in (out / 'keys.log').read_text().splitlines()
                      if line.startswith('{'))['public_key']
        config += f'trust:\n  patch: {public}\n'
        key = ['--key-file', out / 'keys.json']
    write(app / 'flutter_patcher.yaml', config)
    (out / 'store').mkdir()
    patcher('build', 'build', 'android', *common, '--project', app, '--channel', 'device',
            '--strategy', args.strategy, '--version-code', '1', '--out', out / 'release')
    built = json.loads((out / 'release/build.json').read_text())

    if args.strategy == 'so':  # Bytecode patches replace Dart code only.
        write(app / 'assets/msg.txt', 'asset-patched')
    for n, revision, crash in [(1, 'patched', False), (2, 'crash', True), (3, 'patched-3', False)]:
        main = source.replace("const revision = 'original';", f"const revision = '{revision}';")
        write(app / 'lib/main.dart', main.replace('const crash = false;', f'const crash = {str(crash).lower()};'))
        patcher(f'patch{n}', 'patch', 'android', *common, '--project', app, '--fingerprint',
                built['fingerprint'], '--version-code', '1', '--out', out / f'patch{n}')

    name = '1-default-device-arm64-v8a.fptc'
    # Sequences 1, 2, 3, a withdrawal as 4, and patch 1 again as 5: the rollback.
    for seq, patch, extra in [(1, 1, []), (2, 2, []), (3, 3, []), (4, 3, ['--withdraw']), (5, 1, [])]:
        patcher(f'publish{seq}', 'publish', '--project', app, '--patch', out / f'patch{patch}', *extra,
                '--seq', str(seq), '--yes', *key)
        shutil.copyfile(srv / 'pub' / name, srv / f'file{seq}.fptc')
    write_bytes = (srv / 'file1.fptc').read_bytes()
    # A flipped signature byte (signed) or payload byte (unsigned) must fail on the device.
    offset = 100 if args.signing == 'signed' else len(write_bytes) - 1
    (srv / 'tampered.fptc').write_bytes(write_bytes[:offset] + bytes([write_bytes[offset] ^ 1])
                                        + write_bytes[offset + 1:])
    write(out / 'file-name.txt', name)


def remote_prepare(args, repo, out):
    """Run --prepare-only on `args.remote` from a source snapshot; fetch what verify needs."""
    root = f'{args.remote_root}/{out.name}'
    ssh = lambda command: subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=30',
                                          args.remote, command], check=True)
    snapshot(repo, out)
    ssh(shlex.join(['mkdir', '-p', root]))
    subprocess.run(['scp', '-q', str(out / 'source.tar.gz'), f'{args.remote}:{root}/'], check=True)
    print(f'STAGE remote-prepare {args.remote}:{root}', flush=True)
    prepare = shlex.join(['python3', 'source/test/acceptance/device_acceptance.py', '--prepare-only',
                          '--strategy', args.strategy, '--signing', args.signing,
                          '--flutter-sdk', args.remote_flutter, '--out', 'out'])
    # The key and the baseline store stay on the builder; verify needs only the APK, origin and TLS.
    ssh(f'cd {shlex.quote(root)} && tar -xzf source.tar.gz && ANDROID_HOME={shlex.quote(args.remote_android)} '
        f'{prepare} > prepare.log 2>&1; code=$?; tar --exclude=./app --exclude=./store --exclude=./keys.json '
        f'-czf outputs.tar.gz prepare.log -C out .; exit $code')
    subprocess.run(['scp', '-q', f'{args.remote}:{root}/outputs.tar.gz', str(out)], check=True)
    with tarfile.open(out / 'outputs.tar.gz') as archive:
        archive.extractall(out, filter='data')


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
        name = (out / 'file-name.txt').read_text().strip()

        def offer(file):  # The device finds its file in the store by name.
            shutil.copyfile(srv / file, srv / 'pub' / name)
            return control('/check', {'url': ORIGIN + '/pub'})

        check = lambda n: lambda: offer(f'file{n}.fptc')
        plan = [
            ('original boot', launch, original),
            ('target names the file', lambda: control('/target'),
             {'file': name, 'signed': args.signing == 'signed', 'accepted': 0}),
            ('tampered file rejected', lambda: offer('tampered.fptc'),
             {'update': True, 'ok': False, 'error': 'signatureInvalid'}),
            ('app fetches the file itself', lambda: control('/fetch', {'url': ORIGIN + '/file1.fptc'}),
             {'ok': True}),
            ('the same file is not new', check(1), {'update': False}),
            ('patched boot', launch, patched),
            ('patched second boot', launch, patched),
            ('rollback', lambda: control('/rollback', {}), {'ok': True}),
            ('original after rollback', launch, original),
            ('the rolled back file is not new', check(1), {'update': False}),
            ('apply crash patch', check(2), {'update': True, 'ok': True}),
            ('crash patch does not start', lambda: {'crash_started': launch().get('revision') == 'crash'},
             {'crash_started': False}),
            ('crash protection recovers', launch, {**original, 'diagnostic': 'droppedCircuitBreaker'}),
            ('apply next patch', check(3), {'update': True, 'ok': True}),
            ('next patch boots', launch, {**patched, 'revision': 'patched-3', 'version': '3'}),
            ('withdraw', check(4), {'update': True, 'ok': True}),
            ('original after withdraw', launch, original),
            ('an older file is not new after it', check(3), {'update': False}),
            ('patch 1 again as 5', check(5), {'update': True, 'ok': True}),
            ('rolled back to patch 1', launch, {**patched, 'version': '5'}),
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
    parser.add_argument('--signing', choices=['signed', 'unsigned'], default='signed')
    parser.add_argument('--flutter-sdk', type=Path, required=True)
    parser.add_argument('--serial')
    parser.add_argument('--java-home', default=os.environ.get('JAVA_HOME'))
    parser.add_argument('--out', type=Path)
    parser.add_argument('--resume-built', action='store_true',
                        help='Reuse a completed build/patch/publish in --out; rerun device steps only')
    parser.add_argument('--prepare-only', action='store_true', help='Build, patch and publish; skip the device')
    parser.add_argument('--remote', help='SSH host alias that builds, patches and publishes')
    parser.add_argument('--remote-root', default='/root/.flutter_patcher/device')
    parser.add_argument('--remote-flutter', default='/opt/flutter')
    parser.add_argument('--remote-android', default='/opt/android-sdk')
    args = parser.parse_args()
    if not args.prepare_only and not args.serial:
        parser.error('--serial is required unless --prepare-only')
    repo = Path(__file__).resolve().parents[2]
    out = (args.out or repo / '.dart_tool/flutter_patcher/device' /
           f'{args.strategy}-{args.signing}-{datetime.now():%Y%m%d-%H%M%S}').resolve()
    if args.resume_built:
        if not (out / 'srv/file5.fptc').exists():
            raise SystemExit('--resume-built needs a prepared --out')
    else:
        out.mkdir(parents=True, exist_ok=False)
        remote_prepare(args, repo, out) if args.remote else prepare(args, repo, out)
        if args.prepare_only:
            print(f'PREPARED {out}')
            return
    steps, failed = verify(args, out)
    result = dict(status='failed' if failed else 'passed', strategy=args.strategy, signing=args.signing,
                  serial=args.serial,
                  steps=steps, failed=failed)
    write(out / 'result.json', json.dumps(result, indent=2))
    print(f'{result["status"].upper()} {out}')
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()