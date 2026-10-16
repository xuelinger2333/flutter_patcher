"""Linux half of rebuild_regression.py; consumes an immutable source snapshot."""
import argparse
import base64
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import threading
import traceback
import xml.etree.ElementTree as ET

from integration import execute, call
from corpus import generate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    config = json.loads((root / 'config.json').read_text())
    receipt = json.loads((root / 'source.json').read_text())
    code = root / 'source'
    result = {'status': 'failed', 'source': receipt, 'stage': 'verify_source'}
    server = None
    try:
        for name, digest in receipt['files'].items():
            if hashlib.sha256((code / name).read_bytes()).hexdigest() != digest:
                raise ValueError('Source snapshot mismatch: ' + name)
        if hashlib.sha256(json.dumps(receipt['files'], sort_keys=True).encode()).hexdigest() != receipt['source_sha256']:
            raise ValueError('Source manifest digest mismatch')
        sdk = Path(config['flutter'])
        dart = sdk / 'bin/cache/dart-sdk/bin/dart'
        os.environ.update(config.get('build_env', {}))
        os.environ['PATH'] = str(sdk / 'bin') + ':' + os.environ['PATH']
        served = Path(config['served_artifacts'])
        tool_rel = Path(config['version']) / ('flutter_patcher_tools-' + config['version'] + '.dill')
        # Served release folders use a flutter- prefix.
        tool_rel = Path('flutter-' + config['version']) / tool_rel.name
        if hashlib.sha256((served / tool_rel).read_bytes()).hexdigest() != config['tools_sha256']:
            raise ValueError('Pinned tool artifact differs')
        generator = Path(config['fault_modules'])
        if hashlib.sha256(generator.read_bytes()).hexdigest() != config['fault_modules_sha256']:
            raise ValueError('Fault module generator differs')
        server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(SimpleHTTPRequestHandler, directory=str(served)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = 'http://127.0.0.1:' + str(server.server_port)
        binding = config.get('binding', 'standard')
        store = root / 'baseline-store'; store.mkdir()
        for stage in ['build', 'patch']:
            result['stage'] = stage
            (root / 'progress.json').write_text(json.dumps({'stage': stage}))
            print('STAGE ' + stage, flush=True)
            execute(stage, sdk, code, root / (binding + '-' + stage), url, url + '/supported_versions.txt',
                    store.as_uri(), handoff=root / (binding + '-build/handoff.json'),
                    custom_binding=binding == 'custom', source_identity=receipt)
        patch = root / (binding + '-patch')
        data = json.loads((patch / 'handoff.json').read_text())
        tool = patch / ('cache/artifacts/' + config['version'] + '/tools/' + tool_rel.name)
        if hashlib.sha256(tool.read_bytes()).hexdigest() != config['tools_sha256']:
            raise ValueError('Downloaded tool differs')
        result['stage'] = 'corpus'; print('STAGE corpus', flush=True)
        call(['python3', generator, '--dart', dart, '--tool', tool,
              '--platform', sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
              '--interface', patch / 'cache/baselines' / data['fingerprint'] / 'dynamic_interface.yaml',
              '--fingerprint', data['fingerprint'], '--seq', '7', '--tier', data['lean']['tier'],
              '--out', root / 'modules'], code, root / 'modules.log')
        corpus = root / (binding + '-corpus')
        generate(patch / 'lean/patch.fptc', patch / 'whole/patch.fptc', root / 'modules',
                 base64.b64decode((patch / 'TEST_ONLY_seed.base64').read_text()), corpus)
        os.environ['FLUTTER_PATCHER_TEST_CORPUS'] = str(corpus)
        result['stage'] = 'native_tests'; print('STAGE native_tests', flush=True)
        call(['python3', code / 'test/acceptance/native_tests.py', '--repo', code,
              '--flutter', sdk / 'bin/flutter', '--out', root / 'native-host'], code, root / 'native.log')
        call(['bash', 'gradlew', ':flutter_patcher:assembleDebugAndroidTest', '--console=plain'],
             root / 'native-host/android', root / 'instrumentation-build.log')
        counts = dict(tests=0, failures=0, errors=0, skipped=0)
        xmls = list((root / 'native-host/build/flutter_patcher/test-results/testDebugUnitTest').glob('TEST-*.xml'))
        if not xmls: raise ValueError('Missing native test results')
        for path in xmls:
            attrs = ET.parse(path).getroot().attrib
            for key in counts: counts[key] += int(attrs.get(key, 0))
        if counts['failures'] or counts['errors'] or counts['skipped']:
            raise ValueError('Native tests did not all pass: ' + str(counts))
        result.update(status='passed', stage='built', native_tests=counts,
                      apk_bytes=(root / (binding + '-build/release/app-release.apk')).stat().st_size,
                      independent_machine=False)
    except Exception:
        result['error'] = traceback.format_exc()
        print(result['error'], flush=True)
    finally:
        if server: server.shutdown(); server.server_close()
        (root / 'build-result.json').write_text(json.dumps(result, indent=2))
        with tarfile.open(root / 'outputs.tar.gz', 'w:gz') as archive:
            for name in ['build-result.json', 'source.json']:
                archive.add(root / name, arcname=name)
            for p in root.rglob('*'):
                relative = p.relative_to(root)
                if relative.parts[0] in ['source', 'baseline-store']: continue
                if p.is_file() and (p.suffix == '.log' and 'cache' not in relative.parts
                    or p.name == 'handoff.json' or p.name == 'app-release.apk' and 'release' in relative.parts
                    or relative.parts[0].endswith('-corpus')
                    or p.name.startswith('TEST-') and p.suffix == '.xml'
                    or p.name == 'flutter_patcher-debug-androidTest.apk'):
                    archive.add(p, arcname=str(relative))
        digest = hashlib.sha256((root / 'outputs.tar.gz').read_bytes()).hexdigest()
        (root / 'outputs.sha256').write_text(digest)
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
