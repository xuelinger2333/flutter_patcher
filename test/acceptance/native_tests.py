"""Build the plugin's JVM tests inside a disposable Android host project."""
import argparse
import json
from pathlib import Path
import subprocess
from integration import configure_android


def run(repo, flutter, out):
    if out.exists(): raise ValueError('A fresh generated host is required')
    subprocess.run([str(flutter), 'create', '--empty', '--platforms', 'android',
                    '--project-name', 'jvm_app', str(out)], check=True)
    configure_android(out)
    spec = {'name': 'jvm_app', 'environment': {'sdk': '>=3.13.0 <4.0.0'},
            'dependencies': {'flutter': {'sdk': 'flutter'}, 'flutter_patcher': {'path': str(repo)}}}
    (out / 'pubspec.yaml').write_text(json.dumps(spec))
    subprocess.run([str(flutter), 'pub', 'get'], cwd=out, check=True)
    subprocess.run(['bash', 'gradlew', ':flutter_patcher:testDebugUnitTest', '--console=plain'],
                   cwd=out / 'android', check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['repo', 'flutter', 'out']: parser.add_argument('--' + name, type=Path, required=True)
    run(**vars(parser.parse_args()))
