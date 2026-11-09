"""Build, patch, publish and verify a patchable host on a real device.

One command per strategy (`so` or `bytecode`) and signing (`signed` or
`unsigned`). Android: the patch key, the TLS certificate and the HTTPS origin
are generated per run and trusted only by the fixture app; the phone reaches
the origin through `adb reverse`. Requires Python 3, a JDK (keytool), the
Android SDK and an unlocked API 28+ arm64 device.

`--remote HOST` prepares on an SSH build host (e.g. the Linux builder) from a
snapshot of this working tree, fetches the outputs and verifies locally.

`--platform ios` (macOS with Xcode; bytecode hosts) builds with automatic
signing for `--team`, serves the patch files through a cloudflared quick
tunnel (publicly trusted HTTPS) and drives the app through `iproxy` (Homebrew
libimobiledevice) and `xcrun devicectl`. Code signing needs the login
keychain: prepare in the Mac's desktop Terminal with the iPhone attached, then
run the device steps from anywhere on the Mac, e.g. over SSH:

  python3 test/acceptance/device_acceptance.py --platform ios --signing signed \\
    --prepare-only --team TEAM --bundle-id BUNDLE_ID --flutter-sdk SDK --out DIR
  python3 test/acceptance/device_acceptance.py --platform ios --signing signed \\
    --resume-built --flutter-sdk SDK --cloudflared CLOUDFLARED --out DIR
"""
import argparse
from datetime import datetime
import functools
import http.server
import json
import os
import re
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request

from integration import WINDOWS, call, configure_android, dart_binary, flutter_launcher, normalize_line_endings, snapshot

PACKAGE = 'com.example.device_fixture'
CONTROL = 'http://127.0.0.1:8767'
ORIGIN = 'https://localhost:8443'
ABI = {'android': 'arm64-v8a', 'ios': 'ios-arm64'}


def tool(directory, name):
    """`name` inside `directory` when given, else from PATH."""
    path = Path(directory) / (name + ('.exe' if WINDOWS else '')) if directory else shutil.which(name)
    if not path or not Path(path).exists():
        raise RuntimeError(f'{name} not found')
    return path


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')


def configure_ios(app, bundle_id, team):
    """The app's bundle ID and automatic signing for `team` in the Runner target."""
    pbxproj = app / 'ios/Runner.xcodeproj/project.pbxproj'
    # flutter create may have put in the first team Xcode knows; only `team` may sign.
    text = re.sub(r'\n\t*DEVELOPMENT_TEAM = [^;\n]*;', '', pbxproj.read_text(encoding='utf-8'))
    runner = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.deviceFixture;'
    if text.count(runner) != 3:  # Debug, Release, Profile
        raise RuntimeError(f'Unexpected Runner build settings in {pbxproj}')
    text = text.replace(runner, f'CODE_SIGN_STYLE = Automatic;\n\t\t\t\tDEVELOPMENT_TEAM = {team};\n'
                                f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle_id};')
    write(pbxproj, text.replace('com.example.deviceFixture', bundle_id))  # RunnerTests


def configure_android_app(app, ca):
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


def create_app(args, repo, out, ca):
    """The fixture app; it trusts the test CA `ca` (Android) or, without one, public roots only (iOS)."""
    app = out / 'app'
    call([flutter_launcher(args.flutter_sdk), 'create', '--empty', '--platforms', args.platform,
          '--org', 'com.example', '--project-name', 'device_fixture', app], out, out / 'create.log')
    if args.platform == 'ios':
        configure_ios(app, args.bundle_id, args.team)
    else:
        configure_android_app(app, ca)
    write(app / 'pubspec.yaml', json.dumps(dict(
        name='device_fixture', version='1.0.0+1', environment={'sdk': '>=3.8.0 <4.0.0'},
        dependencies={'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': repo.as_posix()}},
        flutter={'assets': ['assets/msg.txt']})))
    write(app / 'assets/msg.txt', 'asset-original')
    source = (repo / 'test/acceptance/app/device_fixture.dart').read_text(encoding='utf-8')
    source = source.replace('__TEST_CA__', ca.read_text().strip() if ca else '')
    write(app / 'lib/main.dart', source)
    normalize_line_endings(app)
    call([flutter_launcher(args.flutter_sdk), 'pub', 'get'], app, out / 'pub.log')
    return app, source


def remove_symlinks(*roots):
    """CocoaPods' generated .symlinks directories make the CLI reject a project."""
    for root in roots:
        for parent, dirs, _ in os.walk(root):
            if '.symlinks' in dirs:
                dirs.remove('.symlinks')
                shutil.rmtree(Path(parent) / '.symlinks')


def prepare(args, repo, out):
    dart, cli = dart_binary(args.flutter_sdk), repo / 'bin/flutter_patcher.dart'
    common = ['--flutter-sdk', args.flutter_sdk]
    ios = args.platform == 'ios'

    def patcher(name, *argv):
        print('STAGE ' + name, flush=True)
        if ios:
            remove_symlinks(repo, out / 'app')
        call([dart, cli, *argv], repo, out / (name + '.log'))

    call([flutter_launcher(args.flutter_sdk), 'pub', 'get'], repo, out / 'cli-pub.log')
    ca = None
    if not ios:  # The iPhone fetches from a publicly trusted origin.
        tls, password = out / 'tls', secrets.token_hex(16)
        tls.mkdir()
        keytool = tool(args.java_home and Path(args.java_home) / 'bin', 'keytool')
        call([keytool, '-genkeypair', '-alias', 'tls', '-keyalg', 'EC', '-groupname', 'secp256r1',
              '-dname', 'CN=localhost', '-ext', 'SAN=dns:localhost', '-validity', '7', '-storetype', 'PKCS12',
              '-keystore', tls / 'tls.p12', '-storepass', password], out, out / 'keytool.log')
        call([keytool, '-exportcert', '-rfc', '-alias', 'tls', '-keystore', tls / 'tls.p12',
              '-storepass', password, '-file', tls / 'test_ca.pem'], out, out / 'keytool-export.log')
        write(tls / 'password.txt', password)
        ca = tls / 'test_ca.pem'
    app, source = create_app(args, repo, out, ca)
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
    # A development export installs on the team's registered devices; build ipa
    # lets automatic signing create or renew the profile.
    patcher('build', 'build', args.platform, *common, '--project', app, '--channel', 'device',
            '--strategy', args.strategy, '--version-code', '1',
            *(['--export-method', 'development'] if ios else []), '--out', out / 'release')
    built = json.loads((out / 'release/build.json').read_text())

    if args.strategy == 'so':  # Bytecode patches replace Dart code only.
        write(app / 'assets/msg.txt', 'asset-patched')
    for n, revision, crash in [(1, 'patched', False), (2, 'crash', True), (3, 'patched-3', False)]:
        main = source.replace("const revision = 'original';", f"const revision = '{revision}';")
        write(app / 'lib/main.dart', main.replace('const crash = false;', f'const crash = {str(crash).lower()};'))
        patcher(f'patch{n}', 'patch', args.platform, *common, '--project', app, '--fingerprint',
                built['fingerprint'], '--version-code', '1', '--out', out / f'patch{n}')

    name = f'1-default-device-{ABI[args.platform]}.fptc'
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
    if ios:
        write(out / 'bundle-id.txt', args.bundle_id)


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


class AndroidDevice:
    """adb: the origin is tls_server.dart on 8443 through `adb reverse`, control through `adb forward`."""

    def __init__(self, args, out):
        sdk = os.environ.get('ANDROID_HOME')
        self.adb = [tool(sdk and Path(sdk) / 'platform-tools', 'adb'), '-s', args.serial]
        self.out = out
        self.server = subprocess.Popen([dart_binary(args.flutter_sdk), Path(__file__).parent / 'tls_server.dart',
                                        out / 'srv', out / 'tls/tls.p12', (out / 'tls/password.txt').read_text()],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def run(self, *a, timeout=180):
        return subprocess.run([*map(str, self.adb), *a], capture_output=True, encoding='utf-8',
                              errors='replace', timeout=timeout)

    def start(self):
        if self.server.stdout.readline().strip() != 'READY':
            raise RuntimeError('TLS server did not start')
        self.run('reverse', 'tcp:8443', 'tcp:8443')
        self.run('forward', 'tcp:8767', 'tcp:8767')
        return ORIGIN

    def uninstall(self):
        self.run('uninstall', PACKAGE)

    def install(self):
        installed = self.run('install', '-r', self.out / 'release/app-release.apk', timeout=600)  # On-device approval.
        if 'Success' not in installed.stdout:
            raise RuntimeError('Install failed: ' + installed.stdout + installed.stderr)
        self.run('logcat', '-c')

    def launch(self):
        self.run('shell', 'am', 'force-stop', PACKAGE)
        time.sleep(2)
        self.run('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity')

    def close(self):
        self.server.kill()
        (self.out / 'tls-server.log').write_text(self.server.stdout.read() or '')
        try:  # Best effort: a disconnected device must not hide the real failure.
            (self.out / 'logcat.txt').write_text(self.run('logcat', '-d', '-v', 'threadtime').stdout, encoding='utf-8')
        except subprocess.TimeoutExpired:
            pass


def devicectl(*a, timeout=180):
    return subprocess.run(['xcrun', 'devicectl', *map(str, a)], capture_output=True, encoding='utf-8',
                          errors='replace', timeout=timeout)


def find_iphone(serial, out):
    """(CoreDevice identifier, UDID) of the attached, paired iPhone; `serial` may be either."""
    listing = out / 'devices.json'
    result = devicectl('list', 'devices', '--json-output', listing, timeout=60)
    if result.returncode:
        raise SystemExit('xcrun devicectl list devices failed: ' + result.stdout + result.stderr)
    found = []
    for d in json.loads(listing.read_text())['result']['devices']:
        hardware, connection = d.get('hardwareProperties', {}), d.get('connectionProperties', {})
        if (hardware.get('reality') == 'physical' and hardware.get('platform') == 'iOS'
                and connection.get('pairingState') == 'paired' and connection.get('tunnelState') != 'unavailable'
                and serial in (None, d['identifier'], hardware.get('udid'))):
            found.append((d['identifier'], hardware.get('udid'), d.get('deviceProperties', {}).get('name')))
    if not found:
        raise SystemExit('No iPhone attached: none is connected, paired and available'
                         + (f' with id {serial}' if serial else '') + ' (see xcrun devicectl list devices)')
    if len(found) > 1:
        raise SystemExit('Several iPhones attached; choose one with --serial: ' + json.dumps(found))
    identifier, udid, name = found[0]
    print(f'DEVICE {name} {identifier} udid={udid}', flush=True)
    return identifier, udid


class _NoStore(http.server.SimpleHTTPRequestHandler):
    """Static files that neither Cloudflare nor the phone may cache: the test swaps them."""

    def do_GET(self):
        del self.headers['If-Modified-Since']
        super().do_GET()

    def do_HEAD(self):
        del self.headers['If-Modified-Since']
        super().do_HEAD()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def log_message(self, format, *args):
        with open(self.server.log, 'a', encoding='utf-8') as log:
            log.write(format % args + '\n')


class IosDevice:
    """devicectl; the origin is `srv` over a cloudflared quick tunnel, control through `iproxy`."""

    def __init__(self, args, out):
        self.out, self.args, self.processes = out, args, []
        self.bundle = (out / 'bundle-id.txt').read_text().strip()
        self.device, self.udid = find_iphone(args.serial, out)
        self.http = None

    def spawn(self, name, command):
        log = open(self.out / f'{name}.log', 'w', encoding='utf-8')
        self.processes.append(subprocess.Popen([str(c) for c in command], stdout=log, stderr=subprocess.STDOUT))
        return self.processes[-1]

    def start(self):
        iproxy = tool(None, 'iproxy')
        self.http = http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(_NoStore, directory=str(self.out / 'srv')))
        self.http.log = self.out / 'http-server.log'
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        tunnel = self.spawn('tunnel', [self.args.cloudflared or tool(None, 'cloudflared'), 'tunnel',
                                       '--no-autoupdate', '--protocol', 'http2',
                                       '--url', f'http://127.0.0.1:{self.http.server_port}'])
        origin = None
        for _ in range(90):
            time.sleep(1)
            text = (self.out / 'tunnel.log').read_text(errors='replace')
            urls = [w for w in text.split() if w.startswith('https://') and w.endswith('.trycloudflare.com')]
            if urls and 'Registered tunnel connection' in text:
                origin = urls[0]
                break
            if tunnel.poll() is not None:
                break
        if not origin:
            raise RuntimeError(f'cloudflared gave no tunnel; see {self.out / "tunnel.log"}')
        # A fresh quick-tunnel name needs a while in DNS; steps start once it serves srv.
        token = secrets.token_hex(8)
        write(self.out / 'srv/probe.txt', token)
        try:
            for _ in range(60):
                probe = subprocess.run(['curl', '-s', '-m', '10', origin + '/probe.txt'], capture_output=True,
                                       text=True)
                if probe.stdout == token:
                    break
                time.sleep(3)
            else:
                raise RuntimeError(f'{origin} does not serve {self.out / "srv"}; see {self.out / "tunnel.log"}')
        finally:
            (self.out / 'srv/probe.txt').unlink()
        print('ORIGIN ' + origin, flush=True)
        # usbmuxd connects to the fixture's loopback server on the phone.
        proxy = self.spawn('iproxy', [iproxy, '-u', self.udid, '-s', '127.0.0.1', '8767:8767'])
        time.sleep(1)
        if proxy.poll() is not None:
            raise RuntimeError(f'iproxy exited; is port 8767 in use? See {self.out / "iproxy.log"}')
        self.spawn('device', [tool(None, 'idevicesyslog'), '-u', self.udid, '-p', 'Runner'])
        return origin

    def uninstall(self):
        devicectl('device', 'uninstall', 'app', '--device', self.device, self.bundle)

    def install(self):
        ipas = list((self.out / 'release').glob('*.ipa'))
        if len(ipas) != 1:
            raise RuntimeError(f'Expected one IPA in {self.out / "release"}')
        payload = self.out / 'ipa'
        shutil.rmtree(payload, ignore_errors=True)
        subprocess.run(['ditto', '-x', '-k', ipas[0], payload], check=True)
        installed = devicectl('device', 'install', 'app', '--device', self.device,
                              next(payload.glob('Payload/*.app')), timeout=600)
        if installed.returncode:
            raise RuntimeError('Install failed: ' + installed.stdout + installed.stderr)

    def stop(self):
        listing = self.out / 'processes.json'
        if devicectl('device', 'info', 'processes', '--device', self.device, '--json-output', listing).returncode:
            return
        for process in json.loads(listing.read_text())['result'].get('runningProcesses', []):
            if '/Runner.app/' in process.get('executable', ''):
                devicectl('device', 'process', 'terminate', '--device', self.device,
                          '--pid', process['processIdentifier'])

    def launch(self):
        self.stop()
        time.sleep(2)
        launched = devicectl('device', 'process', 'launch', '--device', self.device, '--terminate-existing',
                             self.bundle)
        if launched.returncode:  # E.g. a locked phone or an untrusted developer; status then fails.
            print('LAUNCH ' + (launched.stdout + launched.stderr).strip(), flush=True)

    def close(self):
        for process in reversed(self.processes):
            process.terminate()
            try:
                process.wait(10)
            except subprocess.TimeoutExpired:
                process.kill()
        if self.http:
            self.http.shutdown()


def control(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(CONTROL + path, data=data), timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {'http': e.code, **json.loads(e.read() or b'{}')}


def verify(args, out):
    srv = out / 'srv'
    device = (IosDevice if args.platform == 'ios' else AndroidDevice)(args, out)
    steps, failed = [], []
    try:
        origin = device.start()
        device.uninstall()
        try:
            control('/status')
            raise RuntimeError('Another app on the device already serves port 8767; stop it first')
        except OSError:
            pass
        device.install()

        def launch():
            device.launch()
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
            return control('/check', {'url': origin + '/pub'})

        check = lambda n: lambda: offer(f'file{n}.fptc')
        plan = [
            ('original boot', launch, original),
            ('target names the file', lambda: control('/target'),
             {'file': name, 'signed': args.signing == 'signed', 'accepted': 0}),
            ('tampered file rejected', lambda: offer('tampered.fptc'),
             {'update': True, 'ok': False, 'error': 'signatureInvalid'}),
            ('app fetches the file itself', lambda: control('/fetch', {'url': origin + '/file1.fptc'}),
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
        for step, action, expected in plan:
            actual = action()
            ok = all(actual.get(k) == v for k, v in expected.items())
            steps.append(dict(step=step, passed=ok, actual=actual))
            print(('PASS ' if ok else 'FAIL ') + step + ' ' + json.dumps(actual), flush=True)
            if not ok:
                failed.append(step)
                break
    finally:
        device.close()
    return steps, failed


def ios_environment():
    """What the Mac's Xcode, CocoaPods and Homebrew tools need, also in a bare SSH session."""
    os.environ.setdefault('LANG', 'en_US.UTF-8')
    os.environ.setdefault('LC_ALL', 'en_US.UTF-8')
    if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
        os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    if Path('/opt/homebrew/bin').is_dir():
        os.environ['PATH'] = '/opt/homebrew/bin' + os.pathsep + os.environ.get('PATH', '')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--platform', choices=['android', 'ios'], default='android')
    parser.add_argument('--strategy', choices=['so', 'bytecode'], help='Required on Android; iOS is bytecode')
    parser.add_argument('--signing', choices=['signed', 'unsigned'], default='signed')
    parser.add_argument('--flutter-sdk', type=Path, required=True)
    parser.add_argument('--serial', help='adb serial; on iOS optional, a devicectl identifier or UDID')
    parser.add_argument('--java-home', default=os.environ.get('JAVA_HOME'))
    parser.add_argument('--out', type=Path)
    parser.add_argument('--resume-built', action='store_true',
                        help='Reuse a completed build/patch/publish in --out; rerun device steps only')
    parser.add_argument('--prepare-only', action='store_true', help='Build, patch and publish; skip the device')
    parser.add_argument('--remote', help='SSH host alias that builds, patches and publishes')
    parser.add_argument('--remote-root', default='/root/.flutter_patcher/device')
    parser.add_argument('--remote-flutter', default='/opt/flutter')
    parser.add_argument('--remote-android', default='/opt/android-sdk')
    parser.add_argument('--team', help='iOS: Apple development team ID for automatic signing')
    parser.add_argument('--bundle-id', help="iOS: the fixture's bundle ID, unique to the team")
    parser.add_argument('--cloudflared', help='iOS: cloudflared binary (default: from PATH)')
    args = parser.parse_args()
    if args.platform == 'android':
        if not args.strategy:
            parser.error('the following arguments are required: --strategy')
        if not args.prepare_only and not args.serial:
            parser.error('--serial is required unless --prepare-only')
    else:
        if args.strategy == 'so':
            parser.error('iOS hosts are bytecode hosts')
        args.strategy = 'bytecode'
        if args.remote:
            parser.error('--remote is for Android; prepare iOS on the Mac itself')
        if not args.resume_built and not (args.team and args.bundle_id):
            parser.error('--team and --bundle-id are required to prepare iOS')
        if sys.platform != 'darwin':
            parser.error('--platform ios runs on macOS')
        ios_environment()
    repo = Path(__file__).resolve().parents[2]
    out = (args.out or repo / '.dart_tool/flutter_patcher/device' /
           f'{"ios-" if args.platform == "ios" else ""}{args.strategy}-{args.signing}-'
           f'{datetime.now():%Y%m%d-%H%M%S}').resolve()
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
    result = dict(status='failed' if failed else 'passed', platform=args.platform, strategy=args.strategy,
                  signing=args.signing, serial=args.serial,
                  steps=steps, failed=failed)
    write(out / 'result.json', json.dumps(result, indent=2))
    print(f'{result["status"].upper()} {out}')
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()
