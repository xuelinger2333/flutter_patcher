"""Paired real authenticated bootstrap, using an explicit scoped cloud RPC.

Credentials are read without echo; neither URLs nor credentials enter results.
The APK must be built by ffi_boot/build.py and match the RPC's input corpus.
"""
import argparse
import getpass
import hashlib
import json
import re
import subprocess
import time
import urllib.request
import uuid
from pathlib import Path


def run(apk, serial, out, rpc, rounds=20, batches=2):
    out.mkdir(parents=True, exist_ok=False)
    credentials = getpass.getpass('S3 credentials JSON (not echoed): ')
    json.loads(credentials)
    adb = ['adb', '-s', serial]
    package = 'com.example.wp23_acceptance'
    report = dict(status='running', scope='experimental_authenticated_bootstrap',
                  apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest(),
                  driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  rounds=rounds, batches=batches, samples=[], cleanup=[],
                  adoption='not_evaluated',
                  memory_peak='kernel_VmHWM_at_three_second_frame_dwell')

    def save():
        (out / 'result.json').write_text(json.dumps(report, indent=2))

    def call(args):
        return subprocess.check_output(adb + args, text=True,
                                       stderr=subprocess.STDOUT, timeout=120)

    def request(path, body=None, timeout=5):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request('http://127.0.0.1:18767' + path, data=data,
                                     headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response)

    def cloud(value):
        value = dict(value, operation=uuid.uuid4().hex)
        for _ in range(3):
            try:
                result = subprocess.run(['ssh', '-o', 'ConnectTimeout=15',
                    '-o', 'ServerAliveInterval=10', 'gpu', rpc],
                    input=credentials + '\n' + json.dumps(value) + '\n',
                    text=True, capture_output=True, timeout=180)
            except subprocess.TimeoutExpired:
                continue
            if result.returncode == 0 and result.stdout.strip():
                answer = json.loads(result.stdout)
                if 'error' in answer:
                    raise RuntimeError('Scoped cloud operation rejected')
                return answer
            time.sleep(3)
        raise RuntimeError('Scoped cloud operation unavailable')

    def boot(mode, expected, label, log_path):
        call(['shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
              '-c', 'android.intent.category.HOME'])
        time.sleep(1)
        call(['shell', 'am', 'kill', package])
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            found = subprocess.run(adb + ['shell', 'pidof', package],
                                   capture_output=True, text=True, timeout=5)
            if found.returncode == 1 and not found.stdout.strip():
                break
            # am kill may be ignored before the HOME transition finishes.
            call(['shell', 'am', 'kill', package])
            time.sleep(.25)
        else:
            raise RuntimeError('Background process did not exit')
        time.sleep(3)
        offset = log_path.stat().st_size
        started = call(['shell', 'am', 'start', '-W', '-f', '0x10008000',
            '-n', package + '/.MainActivity', '--es', 'route',
            'ffi' if mode == 'ffi' else '/'])
        (out / (label + '.start')).write_text(started)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            try:
                status = request('/status')
                if status.get('frame'):
                    break
            except (OSError, ValueError):
                pass
            time.sleep(.25)
        else:
            raise RuntimeError('Test app did not become ready')
        if status['revision'] != expected:
            raise RuntimeError('Unexpected patch revision')
        time.sleep(3)
        if call(['shell', 'pidof', package]).strip() != str(status['pid']):
            raise RuntimeError('Process did not survive frame dwell')
        proc_status = call(['shell', 'cat', f'/proc/{status["pid"]}/status'])
        (out / (label + '.proc-status')).write_text(proc_status)
        memory = {k: int(v) for k, v in re.findall(
            r'^(VmHWM|VmRSS|VmSwap):\s+(\d+) kB', proc_status, re.MULTILINE)}
        if set(memory) != {'VmHWM', 'VmRSS', 'VmSwap'}:
            raise RuntimeError('Missing process memory counters')
        proc_stat = call(['shell', 'cat', f'/proc/{status["pid"]}/stat'])
        (out / (label + '.proc-stat')).write_text(proc_stat)
        fields = proc_stat.rsplit(')', 1)[1].split()
        cpu_ticks = int(fields[11]) + int(fields[12])
        with log_path.open('rb') as log:
            log.seek(offset)
            lines = log.read().decode('utf-8', errors='replace').splitlines()
        lines = [line for line in lines if len(line.split()) > 2 and
                 line.split()[1] == str(status['pid'])]
        if expected == 'original':
            return
        timings = [line.split('BYTECODE_BOOT_TIMING: ', 1)[1] for line in lines
                   if 'BYTECODE_BOOT_TIMING: ' in line]
        profiles = [json.loads(line.split('BYTECODE_BOOT_PROFILE: ', 1)[1])
                    for line in lines if 'BYTECODE_BOOT_PROFILE: ' in line]
        if len(timings) != 1 or len(profiles) != 1:
            raise RuntimeError('Incomplete bootstrap trace')
        profile = profiles[0]
        if profile['tier'] != expected or (
            profile['dart_channel'].get('ffi') == 1) != (mode == 'ffi'):
            raise RuntimeError('Tier or actual transport mismatch')
        timing = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', timings[0])}
        if sum(timing[k] for k in ['payload_us', 'verify_us',
               'load_and_handshake_us', 'resources_us']) != timing['total_us']:
            raise RuntimeError('Non-reconciled timing')
        total = re.search(r'TotalTime: (\d+)', started)
        return dict(mode=mode, tier=expected, pid=status['pid'], timing=timing,
                    profile=profile, memory_kib=memory, process_cpu_ticks=cpu_ticks,
                    android_total_ms=int(total[1]) if total else None)

    logger = None
    active_run = None
    try:
        install = call(['install', '-r', str(apk)])
        (out / 'install.log').write_text(install)
        if 'Success' not in install:
            raise RuntimeError('Installation failed')
        call(['forward', 'tcp:18767', 'tcp:8767'])
        with (out / 'logcat.txt').open('w', encoding='utf-8') as log:
            logger = subprocess.Popen(adb + ['logcat', '-T', '1', '-v', 'epoch',
                'flutter:I', 'AndroidRuntime:E', '*:S'], stdout=log)
            for batch in range(batches):
                active_run = uuid.uuid4().hex
                if 'Success' not in call(['shell', 'pm', 'clear', package]):
                    raise RuntimeError('Test data reset failed')
                boot('channel', 'original', f'{batch}-original', out / 'logcat.txt')
                if request('/ffi-checks', timeout=10).get('ok') is not True:
                    raise RuntimeError('FFI ownership checks failed')
                for revision, tier in enumerate(['lean', 'whole'], 1):
                    signed = cloud(dict(run=active_run, action='publish',
                                        tier=tier, revision=revision))
                    if request('/signed', {'url': signed['url']}, timeout=150).get('ok') is not True:
                        raise RuntimeError('Signed installation rejected')
                    for index in range(rounds):
                        modes = ['channel', 'ffi'] if (index + batch) % 2 == 0 else ['ffi', 'channel']
                        for mode in modes:
                            row = boot(mode, tier, f'{batch}-{tier}-{index}-{mode}', out / 'logcat.txt')
                            report['samples'].append(dict(row, batch=batch, round=index))
                            save()
                        print(f'batch {batch+1}/{batches} {tier} pair {index+1}/{rounds}: passed', flush=True)
                    if request('/ffi-checks', timeout=10).get('ok') is not True:
                        raise RuntimeError('Patched ownership checks failed')
                cleaned = cloud(dict(run=active_run, action='cleanup'))
                report['cleanup'].append(cleaned)
                if cleaned.get('remaining') != 0:
                    raise RuntimeError('Cleanup incomplete')
                active_run = None
            report['status'] = 'passed'
    except BaseException as error:
        report.update(status='failed', error_type=type(error).__name__)
        if isinstance(error, RuntimeError):
            report['error'] = str(error)  # Only locally defined, URL-free failures.
        exits = subprocess.run(adb + ['shell', 'dumpsys', 'activity', 'exit-info', package],
                               capture_output=True, text=True, timeout=15)
        (out / 'exit-info.txt').write_text(exits.stdout, encoding='utf-8')
        raise
    finally:
        if active_run:
            try:
                report['cleanup'].append(cloud(dict(run=active_run, action='cleanup')))
            except Exception:
                report['cleanup'].append({'status': 'unconfirmed', 'run': active_run})
        if logger:
            logger.terminate()
            logger.wait(timeout=10)
        save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['apk', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ['serial', 'rpc']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--rounds', type=int, default=20)
    parser.add_argument('--batches', type=int, default=2)
    args = parser.parse_args()
    if args.rounds < 1 or args.batches < 1:
        parser.error('Positive counts required')
    run(**vars(args))
