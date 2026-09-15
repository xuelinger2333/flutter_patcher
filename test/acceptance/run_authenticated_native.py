"""Run authenticated state/race tests and a real two-process recovery on Android.

The race class controls HTTPS reads in its own instrumentation process. R2/TLS
end-to-end acceptance is separate; this runner never changes device settings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid


def run(apk, serial, out):
    out.mkdir(parents=True, exist_ok=False)
    adb = ['adb', '-s', serial]
    namespace = 'com.flutter_patcher.flutter_patcher'
    runner = namespace + '.test/androidx.test.runner.AndroidJUnitRunner'
    result = dict(status='failed', device=serial,
                  apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest(), cases=[])
    try:
        installation = subprocess.run(adb + ['install', '-r', str(apk)],
                                      capture_output=True, text=True, timeout=120)
        (out / 'install.log').write_text(installation.stdout + installation.stderr)
        if installation.returncode or 'Success' not in installation.stdout:
            raise RuntimeError('Instrumentation APK installation failed')
        run_id = uuid.uuid4().hex
        jobs = [
            ('state-and-ed25519', namespace + '.AuthenticatedStateDeviceTest,' +
             namespace + '.Ed25519DeviceTest', [], 'OK (11 tests)'),
            ('download-races', namespace + '.AuthenticatedDownloadRaceTest', [], 'OK (1 test)'),
            ('withdraw-kill', namespace + '.AuthenticatedProcessDeathTest',
             ['-e', 'phase', 'withdraw-kill', '-e', 'run_id', run_id], 'withdrawal_durable'),
            ('recover', namespace + '.AuthenticatedProcessDeathTest',
             ['-e', 'phase', 'recover', '-e', 'run_id', run_id], 'OK (1 test)'),
        ]
        for name, classes, args, expected in jobs:
            completed = subprocess.run(adb + ['shell', 'am', 'instrument', '-w', '-e',
                'class', classes, *args, runner], capture_output=True, text=True, timeout=120)
            log = completed.stdout + completed.stderr
            (out / (name + '.log')).write_text(log, encoding='utf-8')
            passed = expected in log and (name != 'withdraw-kill' or 'Process crashed' in log)
            result['cases'].append(dict(name=name, status='passed' if passed else 'failed',
                log_sha256=hashlib.sha256(log.encode()).hexdigest()))
            print(name + ': ' + result['cases'][-1]['status'], flush=True)
            if not passed:
                raise RuntimeError(name + ' failed; see saved instrumentation log')
        result['status'] = 'passed'
    finally:
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--out', type=Path, required=True)
    run(**vars(parser.parse_args()))
