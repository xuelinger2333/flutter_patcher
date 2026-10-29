"""Build, patch, publish and verify an authenticated host on a real device.

One command per strategy (`so` or `bytecode`). Keys, the TLS certificate and
the HTTPS origin are generated per run and trusted only by the fixture app;
the phone reaches the origin through `adb reverse`. Requires Python 3, a JDK
(keytool), the Android SDK and an unlocked API 28+ arm64 device.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import time
import urllib.error
import urllib.request

from integration import WINDOWS, call, configure_android, dart_binary, flutter_launcher, normalize_line_endings

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
    dart, cli = dart_binary(args.flutter_sdk), repo / 'flutter_patcher_cli/bin/flutter_patcher.dart'
    common = ['--flutter-sdk', args.flutter_sdk]

    def patcher(name, *argv):
        print('STAGE ' + name, flush=True)
        call([dart, cli, *argv], repo, out / (name + '.log'))

    call([dart, 'pub', 'get'], repo / 'flutter_patcher_cli', out / 'cli-pub.log')
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

    write(app / 'lib/main.dart', source.replace("const revision = 'original';", "const revision = 'patched';"))
    if args.strategy == 'so':  # Bytecode patches replace Dart code only.
        write(app / 'assets/msg.txt', 'asset-patched')
    patcher('patch', 'patch', 'android', *common, '--project', app, '--fingerprint', built['fingerprint'],
            '--seq', '1', '--version-code', '1', '--baseline-store', store,
            '--private-key', out / 'keys/patch/private-key.base64', '--out', out / 'patch')

    srv, operation = out / 'srv', secrets.token_hex(16)
    version = next(line.split(':', 1)[1].strip() for line in (repo / 'pubspec.yaml').read_text().splitlines()
                   if line.startswith('version:'))
    request = dict(application_id=PACKAGE, store=(srv / 'pub').as_uri(), operation=operation,
                   fields=dict(schema='1', key_id='release', application_id=PACKAGE, channel='device',
                               flavor='default', version_code='1', abi='arm64-v8a',
                               fingerprint=built['fingerprint'], strategy=args.strategy,
                               minPluginVersion=version, revision='1', action='publish', patch_seq='1'),
                   patch=str(out / 'patch/patch.fptc'), public_base_url=ORIGIN + '/pub', baseline_store=store,
                   expected_revision=0, private_key=str(out / 'keys/publisher/private-key.base64'),
                   public_key=str(out / 'keys/publisher/public-key.base64'), created_at=int(time.time()))
    write(out / 'publish-request.json', json.dumps(request, indent=2))
    patcher('publish', 'publish', '--production', '--commit', '--request', out / 'publish-request.json')
    wire = json.loads((srv / 'pub/catalog.json').read_text())['releases'][operation]['wire']
    write(srv / 'manifest.json', wire)
    write(srv / 'tampered.json', tamper(wire))


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
    run = lambda *a: subprocess.run([*map(str, adb), *a], capture_output=True, encoding='utf-8',
                                    errors='replace', timeout=180)
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
        installed = run('install', '-r', out / 'release/app-release.apk')
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

        patched_asset = 'asset-patched' if args.strategy == 'so' else 'asset-original'
        original = dict(revision='original', asset='asset-original', version=None, diagnostic='noPatch')
        patched = dict(revision='patched', asset=patched_asset, version='1', diagnostic='patched')
        def rejected():  # Must fail native verification, not an earlier parse.
            actual = control('/check', {'url': ORIGIN + '/tampered.json'})
            return {**actual, 'native': 'AUTH_UPDATE_REJECTED' in actual.get('error', '')}

        plan = [
            ('original boot', launch, original),
            ('tampered manifest rejected', rejected, {'http': 409, 'native': True}),
            ('check and apply', lambda: control('/check', {'url': ORIGIN + '/manifest.json'}), {'update': True, 'ok': True}),
            ('same manifest is not fresh', lambda: control('/check', {'url': ORIGIN + '/manifest.json'}), {'update': False}),
            ('patched boot', launch, patched),
            ('patched second boot', launch, patched),
            ('rollback', lambda: control('/rollback', {}), {'ok': True}),
            ('original after rollback', launch, original),
            ('replay after rollback', lambda: control('/check', {'url': ORIGIN + '/manifest.json'}), {'update': False}),
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
        (out / 'logcat.txt').write_text(run('logcat', '-d', '-v', 'threadtime').stdout, encoding='utf-8')
    return steps, failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strategy', choices=['so', 'bytecode'], required=True)
    parser.add_argument('--flutter-sdk', type=Path, required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--java-home', default=os.environ.get('JAVA_HOME'))
    parser.add_argument('--out', type=Path)
    parser.add_argument('--resume-built', action='store_true',
                        help='Reuse a completed build/patch/publish in --out; rerun device steps only')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = (args.out or repo / '.dart_tool/flutter_patcher/authenticated' /
           f'{args.strategy}-{datetime.now():%Y%m%d-%H%M%S}').resolve()
    if args.resume_built:
        if not (out / 'srv/manifest.json').exists():
            raise SystemExit('--resume-built needs a prepared --out')
        write(out / 'srv/tampered.json', tamper((out / 'srv/manifest.json').read_text()))
    else:
        out.mkdir(parents=True, exist_ok=False)
        prepare(args, repo, out)
    steps, failed = verify(args, out)
    result = dict(status='failed' if failed else 'passed', strategy=args.strategy, serial=args.serial,
                  steps=steps, failed=failed)
    write(out / 'result.json', json.dumps(result, indent=2))
    print(f'{result["status"].upper()} {out}')
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()