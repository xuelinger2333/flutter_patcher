"""Build an isolated WP23 host and matching patches with newly generated keys.

Run on Linux; output must be new. Keys remain in the private output directory.
"""
import argparse
import base64
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import threading
from integration import call, configure_android


def run(repo, flutter, artifacts, out, custom=False):
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.environ.setdefault('ANDROID_HOME', '/opt/android-sdk')
    dart = flutter/'bin/cache/dart-sdk/bin/dart'
    cli = repo/'flutter_patcher_cli/bin/flutter_patcher.dart'
    keys = {}
    for role in ['patch', 'publisher', 'root']:
        private = subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-outform', 'DER'])
        public = subprocess.check_output(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'], input=private)
        if len(private) != 48 or len(public) != 44: raise ValueError('Unexpected key format')
        for kind, data in [('private', private[-32:]), ('public', public[-32:])]:
            path = out/f'{role}-{kind}.base64'
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f:
                f.write(base64.b64encode(data).decode())
        keys[role] = base64.b64encode(public[-32:]).decode()
    app = out/'app'
    call([flutter/'bin/flutter', 'create', '--empty', '--platforms', 'android', '--org', 'com.example',
          '--project-name', 'wp23_acceptance', app], repo, out/'create.log')
    configure_android(app)
    spec = dict(name='wp23_acceptance', version='1.0.0+1', environment={'sdk': '>=3.13.0 <4.0.0'},
                dependencies={'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': str(repo)}},
                flutter={'uses-material-design': True})
    (app/'pubspec.yaml').write_text(json.dumps(spec))
    source = (repo/'test/acceptance/app/authenticated.dart').read_text()
    if custom:
        source = source.replace('  WidgetsFlutterBinding.ensureInitialized();', '  AcceptanceBinding();')
    else:
        source = source.replace('class AcceptanceBinding extends WidgetsFlutterBinding {}\n', '')
    (app/'lib/main.dart').write_text(source)
    manifest = app/'android/app/src/main/AndroidManifest.xml'
    manifest.write_text(manifest.read_text().replace('<application',
        '<uses-permission android:name="android.permission.INTERNET"/>\n<application', 1))
    policy = dict(schema='1', application_id='com.example.wp23_acceptance', version_code='1',
                  channel='acceptance', flavor='default', abi='arm64-v8a', strategy='bytecode',
                  fptc_key=keys['patch'], root_key=keys['root'], keys='release:'+keys['publisher'])
    (out/'host-policy.json').write_text(json.dumps(policy, sort_keys=True, separators=(',', ':')))
    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(SimpleHTTPRequestHandler, directory=str(artifacts)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}'
    common = ['--flutter-sdk', flutter, '--cache-dir', out/'cache', '--artifacts-url', url,
              '--supported-versions-url', url+'/supported_versions.txt']
    store = out/'baseline-store'; store.mkdir()
    try:
        call([flutter/'bin/flutter', 'pub', 'get'], app, out/'pub.log')
        call([dart, 'pub', 'get'], repo/'flutter_patcher_cli', out/'cli-pub.log')
        call([dart, cli, 'doctor', *common, '--json'], repo, out/'doctor.log')
        print('STAGE authenticated-build', flush=True)
        call([dart, cli, 'build', 'android', '--strategy', 'bytecode', *common,
              '--project', app, '--baseline-store', store.as_uri(), '--public-key', out/'patch-public.base64',
              '--host-policy', out/'host-policy.json', '--version-code', '1', '--out', out/'release'], repo, out/'build.log')
        built = json.loads((out/'release/build.json').read_text())
        for seq, tier in [(7, 'lean'), (8, 'whole')]:
            print('STAGE patch-'+tier, flush=True)
            main = source.replace("const revision = 'original';", f"const revision = '{tier}';")
            if tier == 'whole': main = main.replace('Icons.home', 'Icons.favorite')
            (app/'lib/main.dart').write_text(main)
            call([dart, cli, 'patch', 'android', '--strategy', 'bytecode', *common,
                  '--project', app, '--fingerprint', built['fingerprint'], '--seq', str(seq),
                  '--version-code', '1', '--baseline-store', store.as_uri(), '--private-key', out/'patch-private.base64',
                  '--out', out/tier], repo, out/f'{tier}-patch.log')
            patch = json.loads((out/tier/'patch.json').read_text())
            expected = 'whole' if custom else tier
            if patch.get('tier') != expected:
                raise ValueError(f'Expected {expected}, got {patch.get("tier")} for {tier} control')
        (out/'result.json').write_text(json.dumps(dict(status='built', fingerprint=built['fingerprint'],
             custom=custom, device_verified=False), indent=2))
    finally: server.shutdown(); server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['repo', 'flutter', 'artifacts', 'out']: parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--custom', action='store_true')
    run(**vars(parser.parse_args()))
