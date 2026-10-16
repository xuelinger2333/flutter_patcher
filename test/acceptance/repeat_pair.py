"""Repeat-build gate: compare real engine directories and bind both device runs to their APKs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def verify(artifacts, first, second):
    manifests = []
    for root in [first, second]:
        build = json.loads((root / 'build/handoff.json').read_text())
        patch = json.loads((root / 'patch/handoff.json').read_text())
        device = json.loads((root / 'patch/device/device.json').read_text())
        version = build['sdk']['frameworkVersion']
        engine = root / f'build/cache/artifacts/{version}/engine'
        manifest = json.loads((engine / 'engine.manifest.json').read_text())
        if not patch['independent_machine'] or device['status'] != 'passed':
            raise ValueError('Both independent-host device flows must pass')
        corpus = json.loads((root / 'patch/corpus/corpus.json').read_text())
        expected = {row['id'] for row in corpus['cases']}
        observed = [row['id'] for row in device['cases'] if row['status'] == 'passed']
        if device['scope'] != 'bytecode_fault_matrix' or set(observed) != expected or len(observed) != len(expected):
            raise ValueError('Complete device corpus evidence required for each engine')
        if patch['fingerprint'] != build['fingerprint']:
            raise ValueError('Patch baseline differs from its paired build')
        apk = root / 'build/release/app-release.apk'
        if hashlib.sha256(apk.read_bytes()).hexdigest() != device['apk_sha256']:
            raise ValueError('Device evidence does not belong to this APK')
        doctor_lines = (root / 'build/doctor.log').read_text().splitlines()
        doctor = next(json.loads(line) for line in reversed(doctor_lines) if line.startswith('{'))
        if doctor['engine_build_id'] != manifest['build_id'] or not any(
                row['id'] == 'engine_pair' and row['status'] == 'passed' for row in doctor['checks']):
            raise ValueError('Doctor pairing evidence missing or mismatched')
        manifests.append((engine, manifest))
    if manifests[0][1]['build_id'] == manifests[1][1]['build_id']:
        raise ValueError('Two distinct build executions are required')
    subprocess.run([sys.executable, str(artifacts / 'engine/scripts/artifacts.py'), 'compare',
                    str(manifests[0][0]), str(manifests[1][0])], check=True)
    return {'repeat_build': 'passed', 'build_ids': [row[1]['build_id'] for row in manifests]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['artifacts', 'first', 'second', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        report = verify(args.artifacts, args.first, args.second)
    except Exception as error:
        report = {'repeat_build': 'not_passed', 'reason': str(error)}
    with args.out.open('x') as stream: json.dump(report, stream, indent=2)
    raise SystemExit(0 if report['repeat_build'] == 'passed' else 2)
