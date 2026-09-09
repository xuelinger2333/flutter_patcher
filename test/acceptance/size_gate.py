"""Measured libapp regression gate. An unapproved threshold cannot pass."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def compare(ordinary, patched, threshold_bytes):
    result = {'schema': 1, 'threshold_bytes': threshold_bytes}
    for label, file in [('ordinary', ordinary), ('patcher', patched)]:
        with zipfile.ZipFile(file) as archive:
            content = archive.read('lib/arm64-v8a/libapp.so')
        result[label] = {'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
    delta = result['patcher']['bytes'] - result['ordinary']['bytes']
    result['increment_bytes'] = delta
    result['status'] = ('not_run' if threshold_bytes is None else
                        'passed' if delta <= threshold_bytes else 'failed')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['ordinary', 'patched', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--threshold-bytes', type=int)
    args = parser.parse_args()
    if args.threshold_bytes is not None and args.threshold_bytes < 0:
        parser.error('Threshold must be a reviewed nonnegative byte count')
    result = compare(args.ordinary, args.patched, args.threshold_bytes)
    with args.out.open('x') as stream: json.dump(result, stream, indent=2)
    raise SystemExit(0 if result['status'] == 'passed' else 2)
