"""Device smoke for the unchanged v1 SO path, using the ordinary SDK APK."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading
import time
import urllib.request


def run(apk, so, serial, out):
    out.mkdir(parents=True, exist_ok=False)
    package = 'com.example.acceptance_app'
    report = {'scope': 'v1_so_device', 'status': 'failed', 'cases': []}
    payload = so.read_bytes()
    active = True
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/patch': data = payload
            elif self.path == '/check':
                data = json.dumps({'hasUpdate': True, 'patch': {'version': 'so-fixture',
                    'patchUrl': 'http://127.0.0.1:8765/patch', 'targetVersionCode': 1,
                    'md5': hashlib.md5(payload).hexdigest()}} if active else
                    {'hasUpdate': False, 'rollback': True}).encode()
            else: self.send_error(404); return
            self.send_response(200); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def log_message(self, *_): pass
    server = ThreadingHTTPServer(('127.0.0.1', 8765), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    def adb(*args):
        return subprocess.check_output(['adb', '-s', serial, *args], text=True, timeout=90)
    def request(path, data=None):
        body = None if data is None else json.dumps(data).encode()
        with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8766' + path,
                data=body, headers={'Content-Type': 'application/json'}), timeout=10) as result:
            return json.load(result)
    def boot(expected):
        adb('shell', 'am', 'force-stop', package)
        time.sleep(3)
        adb('shell', 'am', 'start', '-n', package + '/.MainActivity')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                status = request('/status')
                if status['frame']:
                    if status['revision'] != expected: raise AssertionError(status)
                    return status
            except OSError: pass
            time.sleep(.25)
        raise RuntimeError('v1 did not render first frame')
    try:
        if adb('get-state').strip() != 'device': raise RuntimeError('Device required')
        adb('install', '-r', str(apk))
        adb('shell', 'pm', 'clear', package)
        adb('reverse', 'tcp:8765', 'tcp:8765'); adb('forward', 'tcp:8766', 'tcp:8766')
        report['cases'].append(boot('original'))
        result = request('/update', {'url': 'http://127.0.0.1:8765/check'})
        if not result.get('ok'): raise AssertionError(result)
        report['cases'].append(boot('so'))
        active = False
        request('/update', {'url': 'http://127.0.0.1:8765/check'})
        report['cases'].append(boot('original'))
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error); raise
    finally:
        server.shutdown(); server.server_close()
        (out / 'legacy.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['apk', 'so', 'out']: parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--serial', required=True)
    run(**vars(parser.parse_args()))
