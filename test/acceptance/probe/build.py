"""Linux only: independent test APK from a finished frozen regression build.

python build.py --run /root/.../RUN --out /root/.../RUN/channel-probe
Does not edit the source snapshot or production APK. Same test package/signing
as the dedicated acceptance app; install only after the formal matrix finishes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--run', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
run, out = args.run.resolve(), args.out.resolve()
out.mkdir(parents=True, exist_ok=False)
config = json.loads((run / 'config.json').read_text())
baseline = run / 'standard-build'
receipt = json.loads((baseline / 'handoff.json').read_text())
flutter = baseline / 'cache/flutter' / config['version']
assert (flutter / 'bin/flutter').is_file()
os.environ.update(config['build_env'])
os.environ['PATH'] = str(flutter / 'bin') + ':' + os.environ['PATH']
os.environ['GRADLE_USER_HOME'] = str(out / 'gradle')
os.environ['FLUTTER_STORAGE_BASE_URL'] = (baseline / 'cache/mirrors' / config['version'] / receipt['build']['baseline']['build_id']).as_uri() + '/'
project = out / 'app'
def call(command):
    subprocess.run([str(v) for v in command], cwd=out, check=True)
call([flutter / 'bin/flutter', 'create', '--platforms', 'android', '--org', 'com.example',
      '--project-name', 'wp9_acceptance', project])
template = Path(__file__).resolve().parent
(project / 'pubspec.yaml').write_text(json.dumps({'name': 'wp9_acceptance', 'version': '1.0.0+1',
    'environment': {'sdk': '>=3.13.0 <4.0.0'}, 'dependencies': {'flutter': {'sdk': 'flutter'}, 'crypto': '^3.0.6'}}))
(project / 'lib/main.dart').write_bytes((template / 'main.dart').read_bytes())
kotlin = project / 'android/app/src/main/kotlin/com/example/wp9_acceptance'
shutil.copyfile(template / 'MainActivity.kt', kotlin / 'MainActivity.kt')
native = run / 'source/android/src/main/kotlin/com/flutter_patcher/flutter_patcher'
hashes = {}
for name in ['BootChannelProfiler.kt', 'BytecodeEnvelope.kt', 'Ed25519Verifier.kt']:
    source = (native / name).read_bytes()
    hashes[name] = hashlib.sha256(source).hexdigest()
    text = source.decode().replace('package com.flutter_patcher.flutter_patcher',
        'package com.example.wp9_acceptance', 1)
    (kotlin / name).write_text(text)
assets = project / 'android/app/src/main/assets'; assets.mkdir()
corpus = run / 'standard-corpus'
suite = json.loads((corpus / 'corpus.json').read_text())
row = next(v for v in suite['cases'] if v['id'] == 'valid-whole')
data = (corpus / row['file']).read_bytes()
assert hashlib.sha256(data).hexdigest() == row['sha256']
(assets / 'probe.fptc').write_bytes(data)
(assets / 'probe.json').write_text(json.dumps({**row, 'fingerprint': suite['fingerprint'], 'public_key': suite['public_key']}))
gradle = project / 'android/gradle.properties'
gradle.write_text('org.gradle.jvmargs=-Xmx2G -XX:MaxMetaspaceSize=768m\norg.gradle.workers.max=2\norg.gradle.daemon=false\nkotlin.compiler.execution.strategy=in-process\nandroid.useAndroidX=true\n')
subprocess.run([str(flutter / 'bin/flutter'), 'build', 'apk', '--release', '--target-platform', 'android-arm64',
    '--dart-define=PROBE_SHA256=' + row['sha256'], '--dart-define=PROBE_LENGTH=' + str(len(data))], cwd=project, check=True)
apk = out / 'probe.apk'
shutil.copyfile(project / 'build/app/outputs/flutter-apk/app-release.apk', apk)
def engine_hash(path):
    with zipfile.ZipFile(path) as archive:
        return hashlib.sha256(archive.read('lib/arm64-v8a/libflutter.so')).hexdigest()
engine = engine_hash(apk)
assert engine == engine_hash(baseline / 'release/app-release.apk'), 'Probe engine differs from production'
(out / 'build-result.json').write_text(json.dumps({'status': 'passed', 'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
    'libflutter_sha256': engine,
    'production_source': json.loads((run / 'source.json').read_text())['source_sha256'], 'copied_native_sha256': hashes,
    'template_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in template.iterdir() if p.is_file()},
    'payload_bytes': len(data), 'payload_sha256': row['sha256']}, indent=2))
