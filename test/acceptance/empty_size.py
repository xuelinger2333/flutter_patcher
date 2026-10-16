"""Build matched empty applications for the SPEC libapp size regression."""
import argparse
import json
from pathlib import Path
import shutil

from integration import call, configure_android
from size_gate import compare


def run(repo, flutter, out, cache, artifacts_url, support_url, threshold_bytes=None):
    out.mkdir(parents=True, exist_ok=False)
    app = out / 'app'
    call([flutter / 'bin/flutter', 'create', '--empty', '--platforms', 'android',
          '--project-name', 'empty_app', app], repo, out / 'create.log')
    configure_android(app)
    (app / 'pubspec.yaml').write_text(json.dumps({'name': 'empty_app', 'version': '1.0.0+1',
        'environment': {'sdk': '>=3.13.0 <4.0.0'}, 'dependencies': {
            'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': str(repo)}}}))
    (app / 'lib/main.dart').write_text("import 'package:flutter/widgets.dart';\nvoid main() { runApp(const SizedBox.shrink()); }\n")
    call([flutter / 'bin/flutter', 'pub', 'get'], app, out / 'pub.log')
    call([flutter / 'bin/flutter', 'build', 'apk', '--release', '--target-platform', 'android-arm64'],
         app, out / 'ordinary.log')
    ordinary = out / 'ordinary.apk'
    shutil.copyfile(app / 'build/app/outputs/flutter-apk/app-release.apk', ordinary)
    key = out / 'TEST_ONLY_public.base64'
    key.write_text('11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=')
    (out / 'store').mkdir()
    call([flutter / 'bin/cache/dart-sdk/bin/dart', repo / 'flutter_patcher_cli/bin/flutter_patcher.dart',
          'build', 'android', '--strategy', 'bytecode', '--flutter-sdk', flutter,
          '--cache-dir', cache, '--artifacts-url', artifacts_url, '--supported-versions-url', support_url,
          '--project', app, '--public-key', key, '--baseline-store', (out / 'store').as_uri(),
          '--version-code', '1', '--out', out / 'release'], repo, out / 'patcher.log')
    result = compare(ordinary, out / 'release/app-release.apk', threshold_bytes)
    result['fixture'] = 'empty SizedBox, no acceptance controller'
    (out / 'size.json').write_text(json.dumps(result, indent=2))
    if result['status'] == 'failed': raise RuntimeError('Empty libapp size exceeds the reviewed threshold')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['repo', 'flutter', 'out', 'cache']: parser.add_argument('--' + name, type=Path, required=True)
    for name in ['artifacts-url', 'support-url']: parser.add_argument('--' + name, required=True)
    parser.add_argument('--threshold-bytes', type=int)
    result = run(**vars(parser.parse_args()))
    raise SystemExit(0 if result['status'] == 'passed' else 2)
