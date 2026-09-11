"""Snapshot current sources, rebuild on Linux, then test the connected real device."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import tarfile
import time
import uuid


def snapshot(repo, out):
    names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z', '--cached',
                                     '--others', '--exclude-standard']).decode().split('\0')
    files = {}
    with tarfile.open(out / 'source.tar.gz', 'w:gz') as archive:
        for name in sorted(set(names) - {''}):
            path = repo / name
            if not path.exists(): continue  # tracked deletion in the working tree
            if path.is_symlink() or not path.resolve().is_relative_to(repo):
                raise ValueError('Source symlinks/outside paths are not supported: ' + name)
            if not path.is_file(): raise ValueError('Source is not a regular file: ' + name)
            data = path.read_bytes()
            files[name] = hashlib.sha256(data).hexdigest()
            # Archive exactly the hashed bytes, even if an editor changes the file next.
            import io
            info = tarfile.TarInfo('source/' + name)
            info.size = len(data); info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    receipt = {'commit': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
               'source_sha256': hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
               'files': files}
    (out / 'source.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--resume-built', type=Path,
                        help='Test the frozen build from an earlier run in a fresh result directory')
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding='utf-8'))
    repo = Path(__file__).resolve().parents[2]
    run_id = datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
    out = (args.out or repo / '.dart_tool/flutter_patcher/regression' / run_id).resolve()
    out.mkdir(parents=True, exist_ok=False)
    result = {'status': 'failed', 'stage': 'snapshot', 'run_id': run_id}
    host = config['ssh_host']
    base = config['remote_root']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', host): raise ValueError('Use a configured SSH alias')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', base) or '..' in PurePosixPath(base).parts or len(PurePosixPath(base).parts) < 3:
        raise ValueError('Use an absolute dedicated remote root')
    remote = base.rstrip('/') + '/' + run_id
    def ssh(*command, **kwargs):
        return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', host,
                               shlex.join([str(x) for x in command])], **kwargs)
    def phase(name):
        result['stage'] = name
        (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('STAGE ' + name, flush=True)
    try:
        (out / 'config.json').write_text(json.dumps(config, indent=2), encoding='utf-8')
        if args.resume_built:
            origin = args.resume_built.resolve()
            prior_config = json.loads((origin / 'config.json').read_text())
            for key in ['binding', 'version', 'tools_sha256', 'fault_modules_sha256']:
                if config.get(key) != prior_config.get(key):
                    raise ValueError('Resume build configuration differs: ' + key)
            result.update(mode='resume_frozen_build', resumed_build=str(origin))
            result['source'] = json.loads((origin / 'source.json').read_text())
            (out / 'source.json').write_text(json.dumps(result['source'], indent=2))
            archive_path = origin / 'outputs.tar.gz'
            digest_path = origin / 'outputs.sha256'
        else:
            result['mode'] = 'rebuild_current_sources'
            result['source'] = snapshot(repo, out)
            phase('remote_build')
            ssh('mkdir', '-p', base, check=True)
            ssh('mkdir', remote, check=True)
            subprocess.run(['scp', '-q', str(out / 'source.tar.gz'), str(out / 'source.json'),
                            str(out / 'config.json'), host + ':' + remote + '/'], check=True)
            extract = 'import tarfile; from pathlib import Path; r=Path(' + repr(remote) + '); tarfile.open(r/"source.tar.gz").extractall(r, filter="data")'
            ssh('python3', '-c', extract, check=True)
            launch = ('import subprocess; from pathlib import Path; r=Path(' + repr(remote) + '); '
                'log=(r/"worker.log").open("w"); '
                'p=subprocess.Popen(["python3",str(r/"source/test/acceptance/rebuild_worker.py"),"--root",str(r)],'
                'stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True); '
                '(r/"worker.pid").write_text(str(p.pid))')
            ssh('python3', '-c', launch, check=True)
            deadline = time.monotonic() + config.get('build_timeout_seconds', 7200)
            while True:
                probe = ssh('test', '-f', remote + '/outputs.sha256', capture_output=True)
                if probe.returncode == 0: break
                if probe.returncode not in [1, 255]: raise RuntimeError('Remote completion probe failed')
                if time.monotonic() >= deadline: raise TimeoutError('Build timeout; inspect ' + remote)
                time.sleep(20)
            phase('download')
            subprocess.run(['scp', '-q', host + ':' + remote + '/outputs.tar.gz',
                            host + ':' + remote + '/outputs.sha256', str(out)], check=True)
            archive_path = out / 'outputs.tar.gz'
            digest_path = out / 'outputs.sha256'
        if hashlib.sha256(archive_path.read_bytes()).hexdigest() != digest_path.read_text().strip():
            raise ValueError('Downloaded output archive hash mismatch')
        inputs = out / 'inputs'; inputs.mkdir()
        with tarfile.open(archive_path) as archive: archive.extractall(inputs, filter='data')
        build = json.loads((inputs / 'build-result.json').read_text())
        result['build'] = build
        if build['status'] != 'passed': raise RuntimeError('Remote build failed; see inputs/build-result.json')
        if build['source'] != result['source']: raise ValueError('Build source receipt mismatch')
        phase('instrumentation')
        apks = list(inputs.rglob('flutter_patcher-debug-androidTest.apk'))
        if len(apks) != 1: raise ValueError('Expected one instrumentation APK')
        adb = ['adb', '-s', config['serial']]
        subprocess.run(adb + ['install', '-r', str(apks[0])], check=True, timeout=180)
        test = subprocess.run(adb + ['shell', 'am', 'instrument', '-w',
            'com.flutter_patcher.flutter_patcher.test/androidx.test.runner.AndroidJUnitRunner'],
            capture_output=True, text=True, timeout=180)
        (out / 'instrumentation.txt').write_text(test.stdout + test.stderr, encoding='utf-8')
        if test.returncode or not re.search(r'OK \(4 tests\)', test.stdout) or 'FAILURES' in test.stdout:
            raise RuntimeError('Instrumentation did not pass all 4 tests')
        result['instrumentation'] = {'status': 'passed', 'tests': 4}
        phase('matrix')
        subprocess.run([sys.executable, str(repo / 'test/acceptance/run_matrix.py'), '--inputs', str(inputs),
            '--serial', config['serial'], '--dart', config['local_dart'], '--binding', config.get('binding', 'standard'),
            '--out', str(out / 'matrix')], check=True)
        matrix = json.loads((out / 'matrix/result.json').read_text())
        if matrix['status'] != 'passed' or len(matrix['cases']) != 31 or any(c['status'] != 'passed' for c in matrix['cases']):
            raise RuntimeError('Matrix incomplete')
        result.update(status='passed', stage='complete', matrix={'status': 'passed', 'tests': 31,
            'result': 'matrix/result.json'}, apk_bytes=build['apk_bytes'])
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(out / 'result.json', flush=True)


if __name__ == '__main__':
    main()
