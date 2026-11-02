/// Compile-time environment of a Flutter release build: flutter_tools'
/// release `buildModeOptions` plus its flavor define. Baseline and patch
/// kernels must use exactly these, or `kReleaseMode`, `kDebugMode`,
/// `appFlavor` and other `fromEnvironment` constants in patched code differ
/// from the host's (without them a patch saw kReleaseMode == false).
Map<String, String> releaseDefines(String? flavor) => {
      'dart.vm.profile': 'false',
      'dart.vm.product': 'true',
      if (flavor != null && flavor != 'default') 'FLUTTER_APP_FLAVOR': flavor,
    };

List<String> defineArgs(Map<String, String> defines) =>
    [for (final e in defines.entries) '-D${e.key}=${e.value}'];
