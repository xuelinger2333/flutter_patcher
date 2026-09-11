"""Run the standalone channel probe on a real device, after formal acceptance.

python run.py --apk probe.apk --serial SERIAL --out FRESH_DIRECTORY
Installs only the dedicated acceptance package; never changes phone settings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--apk', type=Path, required=True)
parser.add_argument('--serial', required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
result = {'status': 'failed', 'apk_sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(),
          'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'samples': []}
package = 'com.example.wp9_acceptance'
def adb(*command):
    return subprocess.check_output(['adb', '-s', args.serial, *command], text=True,
                                   stderr=subprocess.STDOUT, timeout=180)
def write(): (args.out / 'result.json').write_text(json.dumps(result, indent=2))
logger = None
try:
    install = adb('install', '-r', str(args.apk))
    (args.out / 'install.txt').write_text(install)
    if 'Success' not in install: raise RuntimeError(install)
    logpath = args.out / 'logcat.txt'
    with logpath.open('w', encoding='utf-8') as log:
        logger = subprocess.Popen(['adb', '-s', args.serial, 'logcat', '-T', '1', '-v', 'epoch',
            'flutter:I', 'AndroidRuntime:E', '*:S'], stdout=log)
        for index in range(10):
            # Rotate modes between launches to avoid grouping a mode by time.
            modes = ['empty', 'bytes', 'verified']
            for mode in modes[index % 3:] + modes[:index % 3]:
                adb('shell', 'am', 'force-stop', package)
                time.sleep(3)
                offset = logpath.stat().st_size
                start = adb('shell', 'am', 'start', '-W', '-n', package + '/.MainActivity', '--es', 'probe_mode', mode)
                (args.out / f'{index}-{mode}-start.txt').write_text(start)
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    with logpath.open('rb') as reader:
                        reader.seek(offset); text = reader.read().decode('utf-8', errors='replace')
                    if 'BYTECODE_PROBE_DONE:' in text: break
                    time.sleep(0.25)
                else: raise RuntimeError('Probe timed out: ' + str(index) + ':' + mode)
                time.sleep(3)
                dart, native = {}, {}
                for line in text.splitlines():
                    for prefix, target in [('BYTECODE_PROBE_DART: ', dart), ('BYTECODE_CHANNEL_TIMING: ', native)]:
                        if prefix in line:
                            item = json.loads(line.split(prefix, 1)[1])
                            if item['request'] in target: raise ValueError('Duplicate probe request')
                            target[item['request']] = item
                if len(dart) != 2 or set(dart) != set(native): raise ValueError('Incomplete paired traces')
                phases = set()
                for request, sample in dart.items():
                    if sample['mode'] != mode: raise ValueError('Wrong probe mode')
                    phases.add(sample['phase'])
                    span = native[request]
                    parts = ['decode_us', 'handler_us', 'worker_queue_us', 'operation_us', 'main_queue_us', 'encode_us', 'reply_send_us']
                    if sum(span[k] for k in parts) != span['total_us'] or min(span[k] for k in parts) < 0:
                        raise ValueError('Native spans do not reconcile')
                    if sum(sample[k] for k in ['encode_us', 'callback_wait_us', 'decode_us']) != sample['total_us']:
                        raise ValueError('Dart spans do not reconcile')
                    sample.update(round=index, native=span, outside_java_us=sample['total_us'] - span['total_us'])
                    if sample['outside_java_us'] < 0: raise ValueError('Negative residual')
                    result['samples'].append(sample)
                if phases != {'cold', 'post_frame'}: raise ValueError('Missing phase')
                if adb('shell', 'pidof', package).strip() != str(next(iter(dart.values()))['pid']):
                    raise ValueError('Probe process did not survive dwell')
                (args.out / f'{index}-{mode}-meminfo.txt').write_text(adb('shell', 'dumpsys', 'meminfo', package))
                write()
                print(f'{index + 1}/10 {mode}: paired samples captured', flush=True)
        result['summary'] = {}
        for mode in ['empty', 'bytes', 'verified']:
            for phase in ['cold', 'post_frame']:
                rows = [r for r in result['samples'] if r['mode'] == mode and r['phase'] == phase]
                if len(rows) != 10: raise ValueError('Expected ten samples per cell')
                result['summary'][mode + ':' + phase] = {k: {'mean': statistics.mean(r[k] for r in rows),
                    'median': statistics.median(r[k] for r in rows), 'max': max(r[k] for r in rows)}
                    for k in ['total_us', 'outside_java_us', 'encode_us', 'decode_us', 'rss_bytes', 'max_rss_bytes']}
        result['status'] = 'passed'
except Exception as error:
    result['error'] = str(error)
    raise
finally:
    if logger:
        logger.terminate(); logger.wait(timeout=10)
    write()
