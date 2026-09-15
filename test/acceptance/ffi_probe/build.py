"""Build only the standalone transport APK on the pinned Android engine."""
import argparse,hashlib,json,os,shutil,subprocess,sys,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from integration import configure_android

def build(baseline_root,out):
    out.mkdir(parents=True,exist_ok=False)
    template=Path(__file__).resolve().parent
    config=json.loads((baseline_root/'config.json').read_text())
    baseline=baseline_root/'standard-build'
    receipt=json.loads((baseline/'handoff.json').read_text())
    flutter=baseline/'cache/flutter'/config['version']
    os.environ.update(config['build_env'])
    os.environ['PATH']=str(flutter/'bin')+':'+os.environ['PATH']
    os.environ['FLUTTER_STORAGE_BASE_URL']=(baseline/'cache/mirrors'/config['version']/receipt['build']['baseline']['build_id']).as_uri()+'/'
    app=out/'app'
    subprocess.run([str(flutter/'bin/flutter'),'create','--empty','--platforms','android',
        '--org','com.example','--project-name','wp24_probe',str(app)],check=True)
    configure_android(app)
    (app/'pubspec.yaml').write_text(json.dumps(dict(name='wp24_probe',version='1.0.0+1',
        environment={'sdk':'>=3.13.0 <4.0.0'},dependencies={'flutter':{'sdk':'flutter'}})))
    shutil.copyfile(template/'main.dart',app/'lib/main.dart')
    kotlin=app/'android/app/src/main/kotlin/com/example/wp24_probe'
    shutil.copyfile(template/'MainActivity.kt',kotlin/'MainActivity.kt')
    cpp=app/'android/app/src/main/cpp';cpp.mkdir()
    for name in ['bridge.cpp','CMakeLists.txt']:shutil.copyfile(template/name,cpp/name)
    gradle=app/'android/app/build.gradle.kts'
    gradle.write_text(gradle.read_text()+'''\nandroid {
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    defaultConfig { externalNativeBuild { cmake { arguments += "-DANDROID_STL=c++_static" } } }
    buildTypes { getByName("release") { isMinifyEnabled = false; isShrinkResources = false } }
}\n''')
    assets=app/'android/app/src/main/assets';assets.mkdir()
    block=bytes(range(251))*4096
    for size in [65536,2097152,16777216]:
        (assets/f'payload-{size}.bin').write_bytes((block*((size+len(block)-1)//len(block)))[:size])
    subprocess.run([str(flutter/'bin/flutter'),'build','apk','--release','--target-platform','android-arm64'],cwd=app,check=True)
    apk=out/'probe.apk';shutil.copyfile(app/'build/app/outputs/flutter-apk/app-release.apk',apk)
    def engine(path):
        with zipfile.ZipFile(path) as z:return hashlib.sha256(z.read('lib/arm64-v8a/libflutter.so')).hexdigest()
    assert engine(apk)==engine(baseline/'release/app-release.apk')
    with zipfile.ZipFile(apk) as z:bridge=z.read('lib/arm64-v8a/libwp24_transport.so')
    result=dict(status='built',apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest(),
        engine_sha256=engine(apk),bridge_bytes=len(bridge),bridge_sha256=hashlib.sha256(bridge).hexdigest(),
        fixture='same Kotlin asset reader; no patch state machine',
        source={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in template.iterdir() if p.is_file()})
    (out/'build-result.json').write_text(json.dumps(result,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-root',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    build(**vars(p.parse_args()))
