"""Run immutable WP-9 corpus through real APK/API/cold starts, never adb-inject files."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import struct
import re
import statistics
import threading
import time
import urllib.error
import urllib.request


def run(apk, corpus, serial, package, out, compatibility=False, custom_binding=True, cli=None, dart=None):
    out.mkdir(parents=True, exist_ok=False)
    report = {'schema': 1, 'status': 'failed', 'cases': [], 'device': serial,
              'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
              'scope': 'lower_api_rejection' if compatibility else 'bytecode_fault_matrix'}
    captured = []
    capture_lock = threading.Lock()
    log_process = None
    log_thread = None
    def collect_logs():
        with (out / 'live-logcat.txt').open('w', encoding='utf-8') as output:
            for line in log_process.stdout:
                output.write(line)
                output.flush()
                with capture_lock:
                    captured.append(line)
    def logs_since(started, pid=None):
        with capture_lock:
            lines = list(captured)
        return '\n'.join(line for line in lines
                         if re.match(r'^\s*\d+\.\d+', line)
                         and float(line.split()[0]) >= started
                         and (pid is None or line.split()[1] == str(pid)))
    def adb(*args, timeout=90):
        return subprocess.check_output(['adb', '-s', serial, *args], text=True, timeout=timeout)
    def request(path, data=None):
        body = None if data is None else json.dumps(data).encode()
        req = urllib.request.Request('http://127.0.0.1:8766' + path, data=body,
                                     headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.load(response)
    def status():
        return request('/status')
    def ready():
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                result = status()
                if result['frame'] and result['asset'] != 'pending':
                    # Observe a live process before deliberately ending this cold start.
                    time.sleep(3)
                    observed = status()
                    if observed['pid'] != result['pid'] or not observed['frame']:
                        raise AssertionError('Application did not survive the first-frame dwell')
                    return result
            except (OSError, ValueError, urllib.error.URLError):
                pass
            time.sleep(0.25)
        raise RuntimeError('No live first-frame application within 30 seconds')
    def launch(stop=True, wait=True):
        if stop:
            with (out / 'lifecycle.jsonl').open('a', encoding='utf-8') as log:
                log.write(json.dumps({'time': time.time(), 'action': 'test_force_stop',
                                      'package': package}) + '\n')
            adb('shell', 'am', 'force-stop', package)
            time.sleep(3)
        result = adb('shell', 'am', 'start', *(['-W'] if wait else []), '-n', package + '/.MainActivity')
        match = re.search(r'TotalTime:\s*(\d+)', result)
        return int(match[1]) if match else None
    def sample(expected):
        values = []
        bootstrap = []
        for _ in range(10):
            started = float(adb('shell', 'date', '+%s').strip())
            elapsed = launch()
            current = ready()
            if current['revision'] != expected or elapsed is None:
                raise AssertionError('Cold-start measurement lacks a valid first-frame sample')
            values.append(elapsed)
            if expected != 'original':
                logs = logs_since(started, current['pid'])
                matches = re.findall(r'BYTECODE_BOOT_TIMING: payload_us=(\d+) verify_us=(\d+) load_and_handshake_us=(\d+) resources_us=(\d+) total_us=(\d+)', logs)
                if len(matches) != 1: raise AssertionError('Exactly one bootstrap timing record is required per process')
                measured = [int(v) for v in matches[0]]
                if sum(measured[:4]) != measured[4]: raise AssertionError('Invalid bootstrap stage measurement')
                bootstrap.append(dict(zip(['payload_us', 'verify_us', 'load_and_handshake_us', 'resources_us', 'total_us'], measured)))
        return {'unit': 'ms', 'metric': 'Android am start TotalTime', 'samples': values,
                'median': statistics.median(values), 'p95': sorted(values)[-1],
                'bootstrap': bootstrap, 'bootstrap_over_85ms': any(v['total_us'] > 85000 for v in bootstrap)}
    server = None
    publisher = None
    publisher_log = None
    def publish(file=None):
        if cli is None or dart is None:
            raise ValueError('Production CLI and Dart paths are required for the A1 mock flow')
        command = [str(dart), str(cli), 'publish', '--out', str(out / 'mock')]
        command += ['--patch', str(file), '--version-code', '1'] if file else ['--action', 'withdraw']
        subprocess.run(command, check=True, stdout=publisher_log, stderr=subprocess.STDOUT)
    try:
        if package != 'com.example.wp9_acceptance':
            raise ValueError('Only the dedicated com.example.wp9_acceptance application may be reset')
        if adb('get-state').strip() != 'device':
            raise RuntimeError('Android device required')
        api = int(adb('shell', 'getprop', 'ro.build.version.sdk').strip())
        abi = adb('shell', 'getprop', 'ro.product.cpu.abilist').strip()
        if 'arm64-v8a' not in abi.split(',') or (api < 33 and not compatibility):
            raise RuntimeError('Full bytecode acceptance requires API33+ arm64')
        if compatibility and api >= 33: raise RuntimeError('Compatibility case requires API below 33')
        report.update(api=api, abi=abi, build=adb('shell', 'getprop', 'ro.build.fingerprint').strip())
        log_process = subprocess.Popen(['adb', '-s', serial, 'logcat', '-T', '1', '-v', 'epoch',
            'flutter:I', 'ActivityManager:I', 'AndroidRuntime:E', 'DEBUG:F', '*:S'],
            stdout=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
        log_thread = threading.Thread(target=collect_logs, daemon=True)
        log_thread.start()
        suite = json.loads((corpus / 'corpus.json').read_text())
        active = {}
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/check':
                    data = json.dumps(active['state']).encode()
                elif self.path == '/patch':
                    data = active['bytes']
                else:
                    self.send_error(404); return
                self.send_response(200); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 8765), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        installed = adb('shell', 'pm', 'path', package).strip().splitlines()
        same_apk = False
        if len(installed) == 1 and installed[0].startswith('package:/data/app/'):
            digest = adb('shell', 'sha256sum', installed[0].removeprefix('package:')).split()[0]
            same_apk = digest == report['apk_sha256']
        if not same_apk:
            adb('install', '-r', str(apk))
        report['apk_install'] = 'existing_sha256_verified' if same_apk else 'installed'
        adb('reverse', 'tcp:8765', 'tcp:8765')
        adb('forward', 'tcp:8766', 'tcp:8766')
        for row in (suite['cases'][:1] if compatibility else suite['cases']):
            data = (corpus / row['file']).read_bytes()
            if hashlib.sha256(data).hexdigest() != row['sha256']:
                raise ValueError('Corpus file changed: ' + row['id'])
            active['bytes'] = data
            active['state'] = {'hasUpdate': True, 'patch': {
                'version': row['id'], 'strategy': 'bytecode',
                'patchUrl': 'http://127.0.0.1:8765/patch', 'sha256': row['sha256'],
                'fingerprint': suite['fingerprint'], 'targetVersionCode': 1,
                'patch_seq': struct.unpack_from('>I', data, 38)[0] if len(data) >= 42 else suite['seq']}}
            if row['layer'] == 'state':
                control = next(case for case in suite['cases'] if case['id'] == 'valid-lean')
                active['bytes'] = (corpus / control['file']).read_bytes()
                active['state']['patch'].update(sha256=control['sha256'], patch_seq=suite['seq'])
            # Deliberately reset only the dedicated test app between independent cases.
            adb('shell', 'pm', 'clear', package)
            started = float(adb('shell', 'date', '+%s').strip())
            launch(); initial = ready()
            if initial['revision'] != 'original':
                raise AssertionError('Control host did not start original code')
            if initial['binding'] != custom_binding:
                raise AssertionError('Custom application binding was replaced')
            if row['layer'] == 'accept':
                baseline_timing = sample('original')
                before_image = subprocess.check_output(['adb', '-s', serial, 'exec-out', 'screencap', '-p'])
                (out / (row['id'] + '-before.png')).write_bytes(before_image)
            update_url = 'http://127.0.0.1:8765/check'
            if row['layer'] == 'accept' and not compatibility:
                if publisher_log is None: publisher_log = (out / 'publish.log').open('w')
                publish(corpus / row['file'])
                if publisher is None:
                    publisher = subprocess.Popen([str(dart), str(cli), 'publish', '--action', 'serve',
                        '--out', str(out / 'mock'), '--port', '8767'], stdout=publisher_log, stderr=subprocess.STDOUT)
                    adb('reverse', 'tcp:8767', 'tcp:8767')
                    deadline = time.monotonic() + 15
                    while True:
                        try:
                            with urllib.request.urlopen('http://127.0.0.1:8767/check', timeout=1) as response:
                                if json.load(response)['hasUpdate']: break
                        except OSError:
                            if time.monotonic() >= deadline or publisher.poll() is not None:
                                raise RuntimeError('CLI mock server failed to start')
                            time.sleep(.1)
                update_url = 'http://127.0.0.1:8767/check'
            applied = request('/update', {'url': update_url})
            if compatibility:
                if applied.get('ok') or 'API 33+' not in str(applied):
                    raise AssertionError('Lower API must explicitly reject bytecode: ' + str(applied))
                launch()
                if ready()['revision'] != 'original': raise AssertionError('Lower API original app unavailable')
                report['cases'].append({'id': 'lower-api-rejection', 'status': 'passed', 'apply': applied})
                report['status'] = 'passed'
                return
            if row['layer'] == 'state':
                if not applied.get('ok'): raise AssertionError(applied)
                repeated = request('/update', {'url': 'http://127.0.0.1:8765/check'})
                if not repeated.get('ok'): raise AssertionError('Active identical patch must be idempotent')
                active['state'] = {'hasUpdate': False, 'rollback': True}
                request('/update', {'url': 'http://127.0.0.1:8765/check'})
                active['state'] = {'hasUpdate': True, 'patch': {
                    'version': row['id'], 'strategy': 'bytecode', 'sha256': row['sha256'],
                    'patchUrl': 'http://127.0.0.1:8765/patch', 'fingerprint': suite['fingerprint'],
                    'targetVersionCode': 1, 'patch_seq': struct.unpack_from('>I', data, 38)[0]}}
                active['bytes'] = data
                applied = request('/update', {'url': 'http://127.0.0.1:8765/check'})
            if row['layer'] in ['envelope', 'state']:
                if applied.get('ok') or row['reason'].lower() not in str(applied).lower():
                    raise AssertionError({'case': row, 'apply': applied})
            elif not applied.get('ok'):
                raise AssertionError({'premature_rejection': row, 'apply': applied})
            launch(wait=row['id'] not in ['main-hangs', 'main-throws'])
            if row['id'] == 'main-hangs':
                # Dart can occupy the platform thread: am crash is queued there and
                # cannot execute. Exercise a real input ANR, and prove process death
                # before restarting. Default crash threshold is one, not two.
                time.sleep(3)
                hung_pid = adb('shell', 'pidof', package).strip()
                if not hung_pid.isdigit(): raise AssertionError('Expected one hung process')
                monitor_path = out / 'main-hangs-monitor.txt'
                with monitor_path.open('w', encoding='utf-8') as monitor_log:
                    monitor = subprocess.Popen(['adb', '-s', serial, 'shell', 'am', 'monitor',
                        '-k', '-p', package], stdin=subprocess.PIPE, stdout=monitor_log,
                        stderr=subprocess.STDOUT, text=True)
                    try:
                        deadline = time.monotonic() + 10
                        while 'Monitoring activity manager' not in monitor_path.read_text(encoding='utf-8'):
                            if monitor.poll() is not None or time.monotonic() > deadline:
                                raise AssertionError('ANR monitor did not start')
                            time.sleep(.1)
                        adb('shell', 'input', 'keyevent', '62', timeout=20)
                        deadline = time.monotonic() + 30
                        while True:
                            probe = subprocess.run(['adb', '-s', serial, 'shell', 'pidof', package],
                                                   capture_output=True, text=True, timeout=10)
                            if probe.returncode == 1 and not probe.stdout.strip(): break
                            if probe.returncode != 0 or probe.stdout.strip() != hung_pid:
                                raise AssertionError('Unexpected process during ANR termination')
                            if time.monotonic() > deadline:
                                raise AssertionError('Hung process did not exit after input ANR')
                            time.sleep(.25)
                        exits = adb('shell', 'dumpsys', 'activity', 'exit-info', package)
                        (out / 'main-hangs-injected-exit.txt').write_text(exits, encoding='utf-8')
                        if not re.search(r'pid=' + hung_pid + r'\b(?:(?!ApplicationExitInfo).)*reason=6 \(ANR\)', exits, re.S):
                            raise AssertionError('Hung PID lacks an Android ANR exit record')
                    finally:
                        try: monitor.communicate('q\n', timeout=10)
                        except subprocess.TimeoutExpired:
                            monitor.terminate(); monitor.wait(timeout=10)
                time.sleep(3)
                launch(stop=False, wait=False)
            if row['id'] == 'main-throws':
                # Failure after entering main must quarantine; no unsafe same-isolate fallback.
                time.sleep(6)
                launch()
            after = ready()
            logs = logs_since(started)
            (out / (row['id'] + '.log')).write_text(logs)
            if row['layer'] == 'accept':
                expected = row.get('revision', row['tier'])
                if after['revision'] != expected or after['asset'].strip() != expected:
                    raise AssertionError({'expected': expected, 'actual': after})
                if after['binding'] != custom_binding: raise AssertionError('Patched application binding replaced')
                timing = sample(expected)
                timing['original'] = baseline_timing
                timing['median_added_ms'] = timing['median'] - baseline_timing['median']
                timing['alert_over_85ms'] = timing['median_added_ms'] > 85
                timing['bootstrap_only_measurement'] = True
                (out / (row['id'] + '-timing.json')).write_text(json.dumps(timing, indent=2))
                # Keep the rendered font/icon result for visual verification.
                screenshot = subprocess.check_output(['adb', '-s', serial, 'exec-out', 'screencap', '-p'])
                (out / (row['id'] + '.png')).write_bytes(screenshot)
                publish()
                request('/update', {'url': update_url})
                launch()
                if ready()['revision'] != 'original': raise AssertionError('Withdrawal failed')
            else:
                if after['revision'] != 'original': raise AssertionError(after)
                if row['layer'] in ['archive', 'boot'] and row['reason'] not in logs + str(after):
                    raise AssertionError('Expected rejection missing: ' + row['reason'])
                if row['layer'] in ['archive', 'boot']:
                    if row['id'] not in ['main-hangs', 'main-throws']:
                        launch()
                        if ready()['revision'] != 'original': raise AssertionError('Second boot did not recover')
                    rejected = request('/update', {'url': 'http://127.0.0.1:8765/check'})
                    if rejected.get('ok') or rejected.get('error') != 'blacklisted':
                        raise AssertionError('Failed candidate was not quarantined: ' + str(rejected))
            # Crash records are checked by package, not unrelated system process failures.
            crashes = adb('shell', 'dumpsys', 'activity', 'exit-info', package)
            (out / (row['id'] + '-exit-info.txt')).write_text(crashes)
            if 'ACTIVITY MANAGER PROCESS EXIT INFO' not in crashes:
                raise AssertionError('Android exit-info evidence unavailable')
            if 'REASON_CRASH_NATIVE' in crashes or '(CRASH_NATIVE)' in crashes:
                raise AssertionError('Native crash recorded')
            report['cases'].append({'id': row['id'], 'status': 'passed', 'apply': applied,
                                    'before': initial, 'after': after})
            (out / 'device.json').write_text(json.dumps(report, indent=2))
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        (out / 'device.json').write_text(json.dumps(report, indent=2) + '\n')
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        if server:
            server.shutdown(); server.server_close()
        if publisher:
            publisher.terminate()
            publisher.wait(timeout=10)
        if publisher_log: publisher_log.close()
        if log_process:
            log_process.terminate()
            log_process.wait(timeout=10)
            log_thread.join(timeout=10)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['apk', 'corpus', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--package', required=True)
    parser.add_argument('--compatibility', action='store_true')
    parser.add_argument('--custom-binding', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--dart', type=Path, required=True)
    run(**vars(parser.parse_args()))
