# flutter_patcher consumer ProGuard / R8 rules.
# AGP 会自动把本文件合并进宿主 App 的 release R8 配置。
# 目标：防止 R8 把插件依赖的反射目标 / JNI 符号混淆或裁掉。

# ---- JNI 桥：必须保留 native 方法名，否则 bsdiff .so 按 Java_{pkg}_{class}_{method}
# 规则查不到符号。类名也不能被 rename（JNI 符号包含完整类名）。----
-keepclasseswithmembernames,includedescriptorclasses class com.flutter_patcher.flutter_patcher.BsDiffBridge {
    native <methods>;
}

# ---- Application：被 AndroidManifest 的 android:name 引用，R8 通常会保留，
# 但宿主如果自定义了激进的规则可能误伤，显式 keep 做兜底 ----
-keep class com.flutter_patcher.flutter_patcher.FlutterPatcherApplication { *; }

# ---- Flutter Plugin：被 GeneratedPluginRegistrant 反射注册 ----
-keep class com.flutter_patcher.flutter_patcher.FlutterPatcherPlugin { *; }

# ---- PatchedFlutterLoader 通过反射 set 给 FlutterInjector.flutterLoader，
# Flutter Engine 内部会反射调用 ensureInitializationComplete，
# 保留类 + 构造器 + 被 override 的方法 ----
-keep class com.flutter_patcher.flutter_patcher.PatchedFlutterLoader {
    <init>(...);
    public void ensureInitializationComplete(android.content.Context, java.lang.String[]);
}
