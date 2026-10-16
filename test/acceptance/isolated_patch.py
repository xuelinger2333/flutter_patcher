"""Run inside the acceptance rootfs, first online to provision, then offline.

The surrounding runner must supply a private mount/PID/network namespace and
only the declared SDK, source snapshot, artifact distribution and baseline.
This verifies environment migration, not independent physical machines.
"""
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading

sys.path.insert(0, '/workspace/source/test/acceptance')
import integration


def main():
    provision = sys.argv[1] == 'provision'
    inputs = Path('/inputs')
    receipt = json.loads((inputs / 'source.json').read_text())
    for name, digest in receipt['files'].items():
        assert hashlib.sha256((Path('/workspace/source') / name).read_bytes()).hexdigest() == digest, name
    prior = json.loads((inputs / 'handoff.json').read_text())
    # Keep the real host machine identity: no fake machine-id independence claim.
    assert Path('/etc/machine-id').read_text().strip() == prior['machine_id']
    forbidden = ['/root/.flutter_patcher', '/opt/android-sdk', '/var/run/docker.sock']
    assert all(not Path(p).exists() for p in forbidden)
    evidence = {'schema': 1, 'status': 'failed', 'isolation': 'mount-pid-network-namespaces-and-chroot',
                'independent_machine': False, 'forbidden_paths_absent': forbidden,
                'source_sha256': receipt['source_sha256'],
                'network': subprocess.check_output(['ip', '-j', 'address'], text=True),
                'routes': subprocess.check_output(['ip', '-j', 'route'], text=True),
                'mounts': Path('/proc/mounts').read_text(),
                'namespaces': {n: str(Path('/proc/self/ns', n).readlink()) for n in ['mnt', 'pid', 'net']}}
    if not provision:
        assert [n['ifname'] for n in json.loads(evidence['network'])] == ['lo']
        assert json.loads(evidence['routes']) == []
        cache = Path('/home/acceptance/.flutter_patcher/provision/cache')
        assert not (cache / 'baselines' / prior['fingerprint']).exists()
        assert not (cache / 'baselines' / 'compile' / prior['fingerprint']).exists()
        assert not (cache / 'baselines' / 'release').exists()
        # CLI subprocesses use their own PUB_CACHE rather than the caller's.
        # Both caches originate from this rootfs's online provisioning only.
        shutil.copytree('/home/acceptance/pub-cache', cache / 'pub-cache', dirs_exist_ok=True)
        evidence['baseline_initially_absent'] = True
        evidence['dependencies'] = 'Packages freshly provisioned in this rootfs; copied to CLI PUB_CACHE'
    server = ThreadingHTTPServer(('127.0.0.1', 37037), functools.partial(
        SimpleHTTPRequestHandler, directory='/inputs/artifacts'))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}'
    original_call = integration.call

    class Provisioned(Exception):
        pass

    def prepare_call(args, cwd, log):
        if provision and 'patch' in args and 'android' in args:
            raise Provisioned()
        args = list(args)
        if not provision:
            if 'create' in args or ('pub' in args and 'get' in args):
                args.append('--offline')
            if 'doctor' in args or ('patch' in args and 'android' in args):
                args.append('--offline')
                args[args.index('--cache-dir') + 1] = '/home/acceptance/.flutter_patcher/provision/cache'
        value = original_call(args, cwd, log)
        if not provision and 'doctor' in args:
            original_call([Path('/toolchain/flutter/bin/cache/dart-sdk/bin/dart'),
                Path('/workspace/source/flutter_patcher_cli/bin/flutter_patcher.dart'),
                'baseline', '--action', 'release', '--offline',
                '--cache-dir', '/home/acceptance/.flutter_patcher/provision/cache',
                '--baseline-store', 'file:///inputs/baseline-store', '--flavor', 'default',
                '--version-code', '1', '--flutter-sdk', '/toolchain/flutter'],
                cwd, Path('/work/baseline-import.log'))
        return value

    integration.call = prepare_call
    try:
        try:
            result = integration.execute('patch', Path('/toolchain/flutter'), Path('/workspace/source'),
                Path('/home/acceptance/.flutter_patcher/provision' if provision else
                     '/home/acceptance/.flutter_patcher/patch'), url, url + '/supported_versions.txt',
                'file:///inputs/baseline-store', handoff=inputs / 'handoff.json', custom_binding=True,
                source_identity=receipt)
        except Provisioned:
            if not provision:
                raise
            evidence['status'] = 'provisioned'
        else:
            assert result['independent_machine'] is False
            evidence.update(status='passed', patch=result)
    finally:
        server.shutdown()
        Path('/work/' + ('provision-result.json' if provision else 'isolation-result.json')).write_text(
            json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
