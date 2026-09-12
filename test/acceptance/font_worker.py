"""Build standard/custom text-font controls from an immutable Linux snapshot."""
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import threading
import traceback
import zipfile

from integration import execute


def main():
    root = Path(sys.argv[1]).resolve()
    code = root / 'source'
    receipt = json.loads((root / 'source.json').read_text())
    for name, expected in receipt['files'].items():
        assert hashlib.sha256((code / name).read_bytes()).hexdigest() == expected, name
    sdk = Path('/root/.flutter_patcher/artifacts-builder/cache/flutter-3.47.2')
    os.environ.update(ANDROID_HOME='/opt/android-sdk', PUB_CACHE='/root/.flutter_patcher/wp2-development/pub-cache')
    os.environ['PATH'] = str(sdk / 'bin') + ':' + os.environ['PATH']
    fonts = root / 'fonts'; fonts.mkdir()
    original = fonts / 'original.ttf'; replacement = fonts / 'replacement.ttf'
    shutil.copyfile('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', original)
    shutil.copyfile('/usr/share/fonts/truetype/dejavu/DejaVuSerif-BoldItalic.ttf', replacement)
    shutil.copyfile('/usr/share/doc/fonts-dejavu-core/copyright', fonts / 'LICENSE')
    result = {'status': 'failed', 'scope': 'text_font_controls', 'source': receipt,
              'fonts': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [original, replacement]},
              'bindings': {}}
    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(
        SimpleHTTPRequestHandler, directory='/root/.flutter_patcher/wp9-development/served-pinned'))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}'
    try:
        for binding in ['standard', 'custom']:
            store = root / (binding + '-store'); store.mkdir()
            for stage in ['build', 'patch']:
                print(binding, stage, flush=True)
                execute(stage, sdk, code, root / (binding + '-' + stage), url, url + '/supported_versions.txt',
                        store.as_uri(), handoff=root / (binding + '-build/handoff.json'),
                        custom_binding=binding == 'custom', source_identity=receipt,
                        font_original=original, font_replacement=replacement)
            corpus = root / (binding + '-corpus'); corpus.mkdir()
            rows = []
            for tier in ['lean', 'whole']:
                data = (root / (binding + '-patch') / tier / 'patch.fptc').read_bytes()
                with zipfile.ZipFile(io.BytesIO(data[146:])) as z:
                    manifest = json.loads(z.read('patch_manifest.json'))
                    row = next(f for f in manifest['fonts'] if f['family'] == 'ReviewText')
                    assert row['subset'] is False
                    assert z.read(row['path']) == replacement.read_bytes()
                file = f'valid-{tier}.fptc'; (corpus / file).write_bytes(data)
                rows.append(dict(id=f'valid-{tier}', file=file, layer='accept', reason='', bytes=len(data),
                                 sha256=hashlib.sha256(data).hexdigest(), tier=manifest['tier'], revision=tier))
            suite = dict(schema=1, fingerprint=data[6:38].hex(), seq=7, cases=rows,
                         scope='text_font_controls', device_verified=False)
            (corpus / 'corpus.json').write_text(json.dumps(suite, indent=2))
            result['bindings'][binding] = suite
        result['status'] = 'passed'
    except Exception:
        result['error'] = traceback.format_exc()
        raise
    finally:
        server.shutdown()
        (root / 'result.json').write_text(json.dumps(result, indent=2))
        with tarfile.open(root / 'outputs.tar.gz', 'w:gz') as t:
            t.add(root / 'result.json', arcname='result.json')
            t.add(fonts, arcname='fonts')
            for binding in ['standard', 'custom']:
                for name in ['corpus', 'build', 'patch']:
                    for p in (root / (binding + '-' + name)).rglob('*'):
                        rel = p.relative_to(root)
                        if p.is_file() and ('cache' not in rel.parts and
                            (name == 'corpus' or p.name == 'handoff.json' or p.suffix == '.log' or
                             'release' in rel.parts and p.name in ['app-release.apk', 'build.json'])):
                            t.add(p, arcname=str(rel))
        (root / 'outputs.sha256').write_text(hashlib.sha256((root / 'outputs.tar.gz').read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
