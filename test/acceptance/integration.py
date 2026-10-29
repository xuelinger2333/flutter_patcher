"""Helpers shared by the acceptance scripts."""
import hashlib
import io
import json
import subprocess
import sys
import tarfile

# The harness runs on Windows, Linux and macOS hosts; only launcher names differ.
# Every generated source file is written with LF so all hosts hash identical bytes.
WINDOWS = sys.platform == 'win32'

def flutter_launcher(flutter):
    return flutter / ('bin/flutter.bat' if WINDOWS else 'bin/flutter')


def dart_binary(flutter):
    return flutter / ('bin/cache/dart-sdk/bin/dart.exe' if WINDOWS else 'bin/cache/dart-sdk/bin/dart')


def call(args, cwd, log):
    with log.open('w') as stream:
        result = subprocess.run([str(v) for v in args], cwd=cwd, stdout=stream,
                                stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed; see {log}')


def normalize_line_endings(project):
    """Match a repository checkout: a stock Windows SDK (autocrlf) templates
    CRLF, which the host's native-source provenance would record as a change.
    Windows scripts keep CRLF, as Flutter's own .gitattributes requires."""
    for file in project.rglob('*'):
        if not file.is_file() or file.suffix in {'.bat', '.cmd', '.ps1'}:
            continue
        data = file.read_bytes()
        if b'\r\n' in data and b'\0' not in data:
            file.write_bytes(data.replace(b'\r\n', b'\n'))


def configure_android(project):
    """Bound only our generated fixtures; isolated runs must not accumulate 8G daemons."""
    file = project / 'android/gradle.properties'
    settings = {'org.gradle.jvmargs': '-Xmx2G -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m',
                'org.gradle.workers.max': '2', 'org.gradle.daemon': 'false',
                'kotlin.compiler.execution.strategy': 'in-process'}
    lines = [line for line in file.read_text().splitlines() if line.partition('=')[0] not in settings]
    file.write_text('\n'.join(lines + [key + '=' + value for key, value in settings.items()]) + '\n', newline='\n')


def snapshot(repo, out):
    """Archive tracked and unignored working-tree bytes with a hash receipt."""
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
            info = tarfile.TarInfo('source/' + name)
            info.size = len(data); info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    receipt = {'commit': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
               'source_sha256': hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
               'files': files}
    (out / 'source.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    return receipt
