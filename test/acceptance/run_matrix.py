"""Run all 31 device cases using an archived, matching build/corpus bundle."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess

from device import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--binding', choices=['standard', 'custom'], default='standard')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--functional-only', action='store_true',
                        help='Run all functional cases without extra performance cold starts')
    parser.add_argument('--compact', action='store_true',
                        help='Run each scenario once; omit performance loops and redundant cold starts')
    parser.add_argument('--case', dest='case_id',
                        help='Run one named scenario after validating the complete 31-case corpus')
    parser.add_argument('--start-index', type=int, default=0,
                        help='First corpus index for a separated batch')
    parser.add_argument('--limit', type=int,
                        help='Maximum scenarios in a separated batch (at most 20)')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = args.out or repo / '.dart_tool/flutter_patcher/matrix' / datetime.now().strftime('%Y%m%d-%H%M%S')
    build = args.inputs / (args.binding + '-build')
    corpus = args.inputs / (args.binding + '-corpus')
    apk = build / 'release/app-release.apk'
    receipt = json.loads((build / 'handoff.json').read_text(encoding='utf-8'))
    suite = json.loads((corpus / 'corpus.json').read_text(encoding='utf-8'))
    if hashlib.sha256(apk.read_bytes()).hexdigest() != receipt['build']['apk_sha256']:
        raise ValueError('APK does not match build receipt')
    if suite['fingerprint'] != receipt['fingerprint']:
        raise ValueError('Corpus fingerprint does not match APK receipt')
    if len(suite['cases']) != 31 or len({row['id'] for row in suite['cases']}) != 31:
        raise ValueError('Exactly 31 distinct cases are required')
    if args.case_id is not None and (args.start_index or args.limit is not None):
        raise ValueError('--case cannot be combined with batch selection')
    if args.limit is not None and (args.limit < 1 or args.limit > 20):
        raise ValueError('--limit must be between 1 and 20')
    if args.start_index < 0 or args.start_index >= len(suite['cases']):
        raise ValueError('--start-index outside corpus')
    if args.limit is not None and args.start_index + args.limit > len(suite['cases']):
        raise ValueError('Batch exceeds corpus')
    for row in suite['cases']:
        data = (corpus / row['file']).read_bytes()
        if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
            raise ValueError('Corpus integrity failure: ' + row['id'])
    out = out.resolve()
    if out.exists():
        raise ValueError('Use a fresh output directory; previous results are immutable')
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.with_suffix('.system.log').open('w', encoding='utf-8') as log:
        logger = subprocess.Popen(['adb', '-s', args.serial, 'logcat', '-T', '1', '-v', 'threadtime',
                                   'ActivityManager:I', 'AndroidRuntime:E', 'flutter:I', '*:S'], stdout=log)
        try:
            run(apk.resolve(), corpus.resolve(), args.serial, 'com.example.acceptance_app', out,
                custom_binding=args.binding == 'custom',
                functional_only=args.functional_only,
                compact=args.compact,
                case_id=args.case_id,
                start_index=args.start_index,
                limit=args.limit,
                cli=repo / 'flutter_patcher_cli/bin/flutter_patcher.dart', dart=args.dart.resolve())
        finally:
            logger.terminate()
            logger.wait(timeout=10)
    result = json.loads((out / 'result.json').read_text())
    expected_cases = (1 if args.case_id else
                      (args.limit if args.limit is not None else len(suite['cases']) - args.start_index))
    if result['status'] != 'passed' or len(result['cases']) != expected_cases:
        raise RuntimeError('Incomplete matrix: ' + str(out / 'result.json'))
    print(out / 'result.json')


if __name__ == '__main__':
    main()
