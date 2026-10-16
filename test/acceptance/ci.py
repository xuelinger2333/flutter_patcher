"""Trusted self-hosted entry point. Runner configuration is local, not PR-controlled."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlparse, unquote

from integration import execute, call
from corpus import generate
from device import run as device_run
from legacy import run as legacy_run
from empty_size import run as empty_size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=['build', 'patch'], required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--binding', choices=['standard', 'custom'], default='standard')
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(Path(os.environ['FLUTTER_PATCHER_RUNNER_CONFIG']).read_text())[args.version]
    run_id = os.environ['GITHUB_RUN_ID'] + '-' + os.environ['GITHUB_RUN_ATTEMPT']
    if not all(c.isdigit() or c == '-' for c in run_id): raise ValueError('Invalid run id')
    repo = Path(__file__).resolve().parents[2]
    flutter = Path(config['flutter'])
    exchange = Path(config['exchange']) / run_id / args.version / args.binding
    out = Path.home() / '.flutter_patcher/ci' / run_id / args.version / args.binding / args.stage
    shared = exchange / 'handoff.json'
    baseline_store = config['baseline_store'].rstrip('/') + '/' + run_id + '/' + args.version + '/' + args.binding
    parsed_store = urlparse(baseline_store)
    if args.stage == 'build' and parsed_store.scheme == 'file':
        Path(unquote(parsed_store.path)).mkdir(parents=True, exist_ok=False)
    receipt = execute(args.stage, flutter, repo, out, config['artifacts_url'],
        config['support_url'], baseline_store, handoff=shared, custom_binding=args.binding == 'custom')
    if args.stage == 'build':
        exchange.mkdir(parents=True, exist_ok=False)
        shutil.copyfile(out / 'handoff.json', shared)
        shutil.copyfile(out / 'release/app-release.apk', exchange / 'app-release.apk')
        shutil.copyfile(out / 'ordinary.apk', exchange / 'ordinary.apk')
        shutil.copyfile(out / 'legacy-libapp.so', exchange / 'legacy-libapp.so')
        if args.binding == 'standard':
            size = empty_size(repo, flutter, out / 'empty-size', out / 'cache',
                config['artifacts_url'], config['support_url'], config.get('size_threshold_bytes'))
            (exchange / 'size.json').write_text(json.dumps(size, indent=2))
            if size['status'] == 'not_run':
                print('::warning::Empty-app size measured; threshold still requires review')
        return
    if not receipt['independent_machine']:
        raise RuntimeError('Cross-host acceptance requires a second machine/VM, not another directory on the build host')
    tool = out / f'cache/artifacts/{args.version}/tools/flutter_patcher_tools-{args.version}.dill'
    tool_manifest = json.loads((tool.parent / 'tools.manifest.json').read_text())
    artifact_commit = subprocess.check_output(['git', '-C', str(args.artifacts), 'rev-parse', 'HEAD'], text=True).strip()
    if tool_manifest['builder_repo_commit'] != artifact_commit:
        raise RuntimeError('Downloaded CI snapshot does not match the selected artifacts commit')
    dart = flutter / 'bin/cache/dart-sdk/bin/dart'
    modules = out / 'fault-modules'
    call([sys.executable, args.artifacts / 'tools/release/fault_modules.py', '--dart', dart,
          '--tool', tool, '--platform', flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
          '--interface', out / 'cache/baselines' / receipt['fingerprint'] / 'dynamic_interface.yaml',
          '--fingerprint', receipt['fingerprint'], '--seq', '7', '--tier', receipt['lean']['tier'],
          '--out', modules], repo, out / 'fault-modules.log')
    corpus = out / 'corpus'
    generate(out / 'lean/patch.fptc', out / 'whole/patch.fptc', modules,
             base64.b64decode((out / 'TEST_ONLY_seed.base64').read_text()), corpus)
    os.environ['FLUTTER_PATCHER_TEST_CORPUS'] = str(corpus)
    call([flutter / 'bin/flutter', 'test', 'test/acceptance/corpus_check.dart'], repo, out / 'corpus-dart.log')
    call(['bash', 'gradlew', ':flutter_patcher:testDebugUnitTest', '--console=plain'],
         out / 'app/android', out / 'native.log')
    device_run(exchange / 'app-release.apk', corpus, config['serial'],
               'com.example.acceptance_app', out / 'device', custom_binding=args.binding == 'custom',
               cli=repo / 'flutter_patcher_cli/bin/flutter_patcher.dart', dart=dart)
    for timing_file in (out / 'device').glob('*-timing.json'):
        timing = json.loads(timing_file.read_text())
        if timing['bootstrap_over_85ms']:
            print('::warning::Bytecode bootstrap exceeded the 85 ms budget; see ' + str(timing_file))
    legacy_run(exchange / 'ordinary.apk', exchange / 'legacy-libapp.so', config['serial'], out / 'legacy')
    if config.get('lower_api_serial'):
        device_run(exchange / 'app-release.apk', corpus, config['lower_api_serial'],
                   'com.example.acceptance_app', out / 'lower-api', compatibility=True,
                   custom_binding=args.binding == 'custom')
    shutil.copyfile(out / 'device/device.json', exchange / 'device.json')
    # Passing this job proves its listed scope, not every acceptance or performance obligation.
    (exchange / 'scope.json').write_text(json.dumps({'cross_machine': 'passed',
        'fault_device_suite': 'passed', 'all_obligations_complete': False,
        'pending': [item for item in ['repeat-build device comparison', 'font visual review',
                    'size threshold review' if config.get('size_threshold_bytes') is None else None,
                    'lower API device' if not config.get('lower_api_serial') else None] if item is not None]}))


if __name__ == '__main__': main()
