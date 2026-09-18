# flutter_patcher consumer ProGuard / R8 rules.
# AGP merges this file into the host app release R8 configuration.
# Goal: keep the small set of Android / Flutter classes referenced by manifest
# entries or startup reflection.

# Application: referenced by AndroidManifest android:name.
-keep class com.flutter_patcher.flutter_patcher.FlutterPatcherApplication { *; }

# Auto-init ContentProvider: declared by the plugin manifest.
-keep class com.flutter_patcher.flutter_patcher.FlutterPatcherAutoInitProvider { *; }

# Flutter plugin: registered by GeneratedPluginRegistrant.
-keep class com.flutter_patcher.flutter_patcher.FlutterPatcherPlugin { *; }

# PatchedFlutterLoader is installed reflectively and overrides engine init.
-keep class com.flutter_patcher.flutter_patcher.PatchedFlutterLoader {
    <init>(...);
    public void ensureInitializationComplete(android.content.Context, java.lang.String[]);
}

# Flutter Engine reflection targets used by LoaderHook.
-keep class io.flutter.FlutterInjector { *; }
-keep class io.flutter.embedding.engine.loader.FlutterLoader { *; }
-keep class com.flutter_patcher.flutter_patcher.BootstrapBridge { *; }
