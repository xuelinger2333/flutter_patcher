"""Apply a transport prototype only to a new disposable source copy, then build.

Never edits the input repository or enables FFI in the production plugin.
"""
import argparse,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path

def build(repo,flutter,artifacts,out):
    out.mkdir(parents=True,exist_ok=False)
    source=out/'source'
    # This input is a source snapshot. "lib/src/build" is CLI source, not output.
    shutil.copytree(repo,source,ignore=shutil.ignore_patterns('.git','.dart_tool','.gradle','__pycache__'))
    template=Path(__file__).resolve().parent
    kotlin=source/'android/src/main/kotlin/com/flutter_patcher/flutter_patcher'
    shutil.copyfile(template/'FfiBootBridge.kt',kotlin/'FfiBootBridge.kt')
    plugin=kotlin/'FlutterPatcherPlugin.kt'
    text=plugin.read_text();needle='bytecode = BytecodePatchManager(appContext)'
    assert text.count(needle)==1
    plugin.write_text(text.replace(needle,needle+'\n        FfiBootBridge(bytecode)'))
    cpp=source/'android/src/main/cpp';cpp.mkdir(parents=True)
    shutil.copyfile(template/'bridge.cpp',cpp/'bridge.cpp')
    (cpp/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.22.1)
project(wp24_boot LANGUAGES CXX)
add_library(wp24_boot SHARED bridge.cpp)
target_compile_features(wp24_boot PRIVATE cxx_std_17)
target_compile_options(wp24_boot PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
''')
    gradle=source/'android/build.gradle'
    gradle.write_text(gradle.read_text()+'''
android {
    externalNativeBuild { cmake { path file('src/main/cpp/CMakeLists.txt'); version '3.22.1' } }
    defaultConfig { externalNativeBuild { cmake { arguments '-DANDROID_STL=c++_static' } } }
}
''')
    rules=source/'android/consumer-rules.pro'
    rules.write_text(rules.read_text()+'\n-keep class com.flutter_patcher.flutter_patcher.FfiBootBridge { *; }\n')
    bootstrap=source/'lib/src/patch_bootstrap.dart'
    text=bootstrap.read_text();assert text.count('call: rawPatcherCall,')==1
    bootstrap.write_text(text.replace("import 'bootstrap/raw_channel.dart';","import 'bootstrap/ffi_raw_call.dart';")
        .replace('call: rawPatcherCall,','call: wp24RawCall,'))
    shutil.copyfile(template/'ffi_raw_call.dart',source/'lib/src/bootstrap/ffi_raw_call.dart')
    fixture=source/'test/acceptance/app/authenticated.dart'
    fixture_text=fixture.read_text().replace('runApp(MaterialApp(home:',"runApp(MaterialApp(initialRoute: '/', home:")
    fixture_text="import 'package:flutter_patcher/src/bootstrap/ffi_raw_call.dart';\n"+fixture_text
    fixture_text=fixture_text.replace("if (request.uri.path == '/status') {", "if (request.uri.path == '/ffi-checks') {\n        await wp24OwnershipChecks();\n        request.response.write('{\"ok\":true}');\n      } else if (request.uri.path == '/status') {")
    fixture.write_text(fixture_text)
    hashes={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [plugin,bootstrap,gradle,rules,kotlin/'FfiBootBridge.kt',cpp/'bridge.cpp',
            cpp/'CMakeLists.txt',source/'lib/src/bootstrap/ffi_raw_call.dart',fixture]}
    (out/'prototype-source.json').write_text(json.dumps(hashes,indent=2))
    subprocess.run([sys.executable,str(source/'test/acceptance/build_authenticated.py'),
        '--repo',str(source),'--flutter',str(flutter),'--artifacts',str(artifacts),'--out',str(out/'host')],check=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['repo','flutter','artifacts','out']:p.add_argument('--'+name,type=Path,required=True)
    build(**vars(p.parse_args()))
