"""Run CLI tests against an isolated S3 emulator with test-only credentials."""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import time


def run(repo, dart, out):
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, AWS_ACCESS_KEY_ID='test-only', AWS_SECRET_ACCESS_KEY='test-only',
               AWS_DEFAULT_REGION='us-east-1', AWS_EC2_METADATA_DISABLED='true')
    # No inherited AWS session/profile may route a fixture to a real account.
    for key in ['AWS_SESSION_TOKEN', 'AWS_PROFILE', 'AWS_DEFAULT_PROFILE']:
        env.pop(key, None)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    endpoint = f'http://127.0.0.1:{port}'
    env['FLUTTER_PATCHER_TEST_S3_ENDPOINT'] = endpoint
    with (out / 'moto.log').open('w') as log:
        service = subprocess.Popen(['moto_server', '-H', '127.0.0.1', '-p', str(port)], env=env,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            for attempt in range(100):
                if service.poll() is not None: raise RuntimeError('S3 emulator exited')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2): break
                except OSError: time.sleep(.1)
            else: raise RuntimeError('S3 emulator not ready')
            subprocess.run(['aws', '--endpoint-url', endpoint, 's3api', 'create-bucket', '--bucket', 'flutter-patcher-test'],
                           env=env, check=True)
            with (out / 'cli.log').open('w') as output:
                for command in [['analyze'], ['test', '--reporter', 'expanded']]:
                    subprocess.run([str(dart), *command], cwd=repo / 'flutter_patcher_cli', env=env,
                                   stdout=output, stderr=subprocess.STDOUT, check=True)
        finally:
            service.terminate(); service.wait(timeout=15)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['repo', 'dart', 'out']: parser.add_argument('--' + name, type=Path, required=True)
    run(**vars(parser.parse_args()))
