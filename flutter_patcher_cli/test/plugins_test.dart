import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/patch/pipeline.dart';
import 'package:flutter_patcher_cli/src/patch/plugins.dart';
import 'package:flutter_patcher_cli/src/patch/sources.dart';
import 'package:test/test.dart';

// Shape of Flutter's generated registrant (flutter_tools flutter_plugins.dart).
const registrant = """
import 'dart:io'; // flutter_ignore: dart_io_import.
import 'package:path_provider_android/path_provider_android.dart' as path_provider_android;
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart' as shared_preferences_foundation;
import 'package:path_provider_windows/path_provider_windows.dart' as path_provider_windows;

@pragma('vm:entry-point')
class _PluginRegistrant {

  @pragma('vm:entry-point')
  static void register() {
    if (Platform.isAndroid) {
      try {
        path_provider_android.PathProviderAndroid.registerWith();
      } catch (err) {
        print('');
      }

    } else if (Platform.isIOS) {
      try {
        shared_preferences_foundation.SharedPreferencesFoundation.registerWith();
      } catch (err) {
        print('');
      }

    } else if (Platform.isWindows) {
      try {
        path_provider_windows.PathProviderWindows.registerWith();
      } catch (err) {
        print('');
      }

    }
  }
}
""";

void main() {
  test('only the target platform registrations reach a whole-tier module', () {
    final ios = platformRegistrations(registrant, 'ios');
    expect(ios.map((r) => r.type), ['SharedPreferencesFoundation']);
    expect(platformRegistrations(registrant, 'android').single.library,
        'package:path_provider_android/path_provider_android.dart');
    final source = pluginRegistrantSource('patch.2.app', 'main.dart', ios);
    expect(
        source, contains("import \"package:patch.2.app/main.dart\" as app;"));
    expect(source, contains('p0.SharedPreferencesFoundation.registerWith();'));
    expect(source, isNot(contains('path_provider')));
    expect(
        patchEntry('patch.2.app', 'main.dart', 2, 'f', 'whole', plugins: true),
        contains(',plugins.patcherMain,'));
  });

  test('FFI in a registered plugin names the whole-tier cause', () {
    expect(
        () => rejectFfi({
              'checks': {
                'ffi': [
                  {
                    'message': 'asFunction',
                    'file':
                        'file:///pub/path_provider_foundation-2.6.0/lib/src/ffi.dart',
                    'line': 3
                  }
                ]
              }
            }, registeredPlugins: {
              'path_provider_foundation':
                  'file:///pub/path_provider_foundation-2.6.0/lib/'
            }),
        throwsA(isA<Failure>()
            .having((f) => f.code, 'code', 'PATCH_FFI_UNSUPPORTED')
            .having((f) => f.message, 'message', contains('whole tier'))));
  });
}
