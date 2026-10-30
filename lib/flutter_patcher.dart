import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel, PlatformException;
import 'package:flutter/widgets.dart';

import 'src/blacklist.dart';
import 'src/boot_diagnostic.dart';
import 'src/io_stub.dart' if (dart.library.io) 'src/io.dart' as platform_io;
import 'src/patch_info.dart';
import 'src/patcher_channel.dart';
import 'src/signed_manifest.dart';

export 'src/blacklist.dart';
export 'src/boot_diagnostic.dart';
export 'src/patch_info.dart';
export 'src/patch_bootstrap.dart';
export 'src/signed_manifest.dart';

/// Android-only Flutter hot-update entrypoint.
///
/// `flutter_patcher` installs signed patches on hosts built with
/// `flutter_patcher build android --host-policy`, and loads them on the next
/// cold start. SO and bytecode hosts share this API.
///
/// Main APIs:
///
/// - [init]: configure crash protection and first-frame boot verification.
/// - [checkUpdate]: fetch and verify a signed publish manifest.
/// - [applyPatch]: download, verify, and install the update it found.
/// - [rollback]: delete the current patch.
///
/// Patches are never swapped into the current process. A successful apply takes
/// effect only after the next cold start.
///
/// {@category Architecture}
/// {@category API-reference}
/// {@category Crash-protection}
class FlutterPatcher {
  FlutterPatcher._();

  static Future<String?>? _strategy;

  /// `so` or `bytecode` for a host built with a host policy, else null.
  static Future<String?> _hostStrategy() =>
      _strategy ??= PatcherChannel.channel.invokeMethod<String>('hostStrategy');

  /// Fetch an untrusted envelope, preserving its exact signed representation.
  /// Authentication and replay checks occur only in [applySignedManifest].
  static Future<SignedManifest> fetchSignedManifest(String url) async =>
      SignedManifest.parse(await platform_io.getSignedWire(url));

  /// Authenticate, download and commit a publication, or persist a withdrawal.
  /// Requires a host built with --host-policy. Failure never enables legacy mode.
  static Future<SignedUpdateResult> applySignedManifest(
      SignedManifest manifest) async {
    final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
        'applySignedManifest', {'wire': manifest.wire});
    if (raw == null) throw StateError('Missing authenticated update result');
    return SignedUpdateResult(
        raw['action'] as String, PatchApplyResult.fromNative(raw));
  }

  /// Apply an independent root-signed key-set update. The carrier is untrusted;
  /// native checks its domain, scope, root signature and durable trust revision.
  static Future<void> updatePublicationTrust(SignedManifest document) async {
    await PatcherChannel.channel.invokeMethod<Object?>(
        'updatePublicationTrust', {'wire': document.wire});
  }

  static bool _inited = false;
  static bool _bootReported = false;
  static bool _bootErrorReported = false;
  static bool _nonAndroidWarned = false;

  /// Whether Dart boot-error hooks can still report failures to native crash
  /// protection. The first frame clears native boot state immediately; this
  /// flag keeps Dart-side blank-screen detection alive for [init]'s
  /// `verifyAfter` window.
  static bool _dartHookActive = true;

  static bool _notAndroidGuard(String method) {
    if (platform_io.isAndroid) return false;
    if (!_nonAndroidWarned) {
      _nonAndroidWarned = true;
      debugPrint(
        '[FlutterPatcher] WARNING: $method called on ${platform_io.operatingSystem}. '
        'This plugin only supports Android; all calls are no-ops. '
        'See README > What Can Be Patched?',
      );
    }
    return true;
  }

  static const EventChannel _eventChannel = EventChannel(
    'flutter_patcher/events',
  );
  static Stream<PatchApplyProgress>? _progressStream;

  /// Broadcast progress stream for [applyPatch].
  ///
  /// Subscribe before calling [applyPatch] to receive `downloading`,
  /// `verifying`, and `finalizing` events. Non-Android platforms return an
  /// empty stream.
  static Stream<PatchApplyProgress> get applyProgress {
    if (_notAndroidGuard('applyProgress')) return const Stream.empty();
    return _progressStream ??= _eventChannel.receiveBroadcastStream().map(
          (raw) => PatchApplyProgress.fromNative(raw),
        );
  }

  /// Initializes patch configuration and crash protection.
  ///
  /// Call this in `main()` before `runApp()`. The method is idempotent.
  ///
  /// [maxCrashCount] defaults to `1` (fail-fast). Once a loaded patch causes an
  /// early boot failure, the SDK rolls it back and blacklists the same payload.
  ///
  /// [loaderFieldCandidates] and [loaderFallbackHeuristic] are advanced Flutter
  /// embedding compatibility controls. Keep defaults unless adapting a new
  /// Flutter version.
  ///
  /// [verifyAfter] is the post-first-frame Dart error watch window.
  static Future<void> init({
    int maxCrashCount = 1,
    List<String> loaderFieldCandidates = const ['flutterLoader'],
    bool loaderFallbackHeuristic = false,
    Duration verifyAfter = const Duration(seconds: 5),
  }) async {
    if (_notAndroidGuard('init')) return;
    if (_inited) return;
    _inited = true;
    _verifyAfter = verifyAfter;

    try {
      await PatcherChannel.markBooting();
    } catch (e, s) {
      _log('markBooting failed: $e', s);
    }

    _installBootErrorCatchers();

    try {
      await PatcherChannel.saveConfig(
        maxCrashCount: maxCrashCount,
        loaderFieldCandidates: loaderFieldCandidates,
        loaderFallbackHeuristic: loaderFallbackHeuristic,
      );
    } catch (e, s) {
      _log('saveConfig failed: $e', s);
    }

    _BootVerifier.start();
  }

  /// Marks the current patched boot as successful and clears native crash
  /// protection state.
  ///
  /// Usually called automatically by [init] after the first frame.
  static Future<void> reportBootSuccess() async {
    if (_notAndroidGuard('reportBootSuccess')) return;
    if (_bootReported) return;
    _bootReported = true;
    try {
      await PatcherChannel.reportBootSuccess();
    } catch (e, s) {
      _log('reportBootSuccess failed: $e', s);
    }
  }

  /// Fetches the signed publish manifest at [url] (HTTPS, written by
  /// `flutter_patcher publish`) and verifies it natively without persisting it.
  /// Only a manifest that would change the accepted state is an update; pass
  /// its [PatchInfo] to [applyPatch].
  ///
  /// Throws [PatcherException] on a host built without a host policy.
  static Future<PatchCheckResult> checkUpdate(
    String url, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_notAndroidGuard('checkUpdate')) {
      return PatchCheckResult.none();
    }

    try {
      if (await _hostStrategy() == null) {
        throw PatcherException('This host has no host policy; build it '
            'with flutter_patcher build android --host-policy');
      }
      return await _checkSigned(url, timeout);
    } on PatcherException {
      rethrow;
    } catch (e, s) {
      _log('checkUpdate failed: $e', s);
      throw PatcherException(e.toString());
    }
  }

  static Future<PatchCheckResult> _checkSigned(String url, Duration timeout) async {
    final manifest =
        SignedManifest.parse(await platform_io.getSignedWire(url, timeout: timeout));
    final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
        'checkSignedManifest', {'wire': manifest.wire});
    if (raw == null || raw['fresh'] != true) return PatchCheckResult.none();
    return PatchCheckResult(
        hasUpdate: true,
        patch: PatchInfo(
            version: raw['patch_seq'] as String? ?? raw['action'] as String,
            raw: {'signed_manifest': manifest.wire, 'action': raw['action']}));
  }

  /// Applies the update [checkUpdate] returned: native code re-verifies the
  /// signed manifest, downloads the patch over HTTPS, verifies its signature,
  /// host fingerprint and sequence, and commits it for the next cold start. A
  /// withdrawal removes the installed patch instead.
  ///
  /// Returns a [PatchApplyResult]. `ok=true` means the patch is installed and
  /// will take effect on the next cold start.
  static Future<PatchApplyResult> applyPatch(
    PatchInfo patchInfo, {
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_notAndroidGuard('applyPatch')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${platform_io.operatingSystem}',
      );
    }
    StreamSubscription<PatchApplyProgress>? sub;
    if (onProgress != null) {
      sub = applyProgress.listen(onProgress);
    }
    try {
      final wire = patchInfo.raw['signed_manifest'];
      if (wire is! String) {
        return PatchApplyResult.failure(PatchApplyError.invalidArgs,
            'Pass the PatchInfo returned by checkUpdate');
      }
      return (await applySignedManifest(SignedManifest.parse(wire))).result;
    } on PlatformException catch (e) {
      // AUTH_UPDATE_IO: the download failed; a later retry may succeed.
      return PatchApplyResult.failure(
          e.code == 'AUTH_UPDATE_IO'
              ? PatchApplyError.network
              : PatchApplyError.unknown,
          e.message);
    } catch (e, s) {
      _log('applyPatch failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
      await sub?.cancel();
    }
  }


  /// Deletes the current patch. The next cold start uses the APK built-in
  /// version. Manual rollback does not blacklist the patch.
  static Future<void> rollback() async {
    if (_notAndroidGuard('rollback')) return;
    try {
      await PatcherChannel.rollback();
    } catch (e, s) {
      _log('rollback failed: $e', s);
    }
  }

  /// Current host APK versionCode. Returns null on failure/non-Android.
  static Future<int?> get appVersionCode async {
    if (_notAndroidGuard('appVersionCode')) return null;
    try {
      return await PatcherChannel.appVersionCode();
    } catch (_) {
      return null;
    }
  }

  /// Current device ABI. Useful when your backend routes patches per ABI.
  static Future<String> get deviceAbi async {
    if (_notAndroidGuard('deviceAbi')) return '';
    try {
      return await PatcherChannel.deviceAbi() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Patch version currently installed on disk.
  ///
  /// A successful `applyPatch` updates this immediately, but the patch is only
  /// loaded by Flutter after the next cold start. Returns null when no patch is
  /// installed.
  static Future<String?> get currentVersion async {
    if (_notAndroidGuard('currentVersion')) return null;
    try {
      final v = await PatcherChannel.currentVersion();
      if (v == null || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Local bad-patch blacklist, ordered from oldest to newest.
  ///
  /// Automatic blacklist triggers include early boot failures, cold-start md5
  /// mismatches, and cold-start signature failures. For asset patches, the md5
  /// is the `patch.zip` payload md5.
  static Future<List<BlacklistEntry>> get blacklist async {
    if (_notAndroidGuard('blacklist')) return const [];
    try {
      final raw = await PatcherChannel.blacklist();
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => BlacklistEntry.fromNative(m))
          .toList(growable: false);
    } catch (e, s) {
      _log('blacklist failed: $e', s);
      return const [];
    }
  }

  /// Clears the local bad-patch blacklist.
  ///
  /// Intended for tests, local debugging, or deliberate operational recovery.
  static Future<void> clearBlacklist() async {
    if (_notAndroidGuard('clearBlacklist')) return;
    try {
      await PatcherChannel.clearBlacklist();
    } catch (e, s) {
      _log('clearBlacklist failed: $e', s);
    }
  }

  /// Last cold-start patch loading diagnostic.
  ///
  /// `applyPatch` reports install-time failures. This getter reports what
  /// happened on the next cold start: version mismatch, md5/signature failure,
  /// crash rollback, loader hook failure, or successful patch load.
  static Future<PatchBootDiagnostic?> get lastBootDiagnostic async {
    if (_notAndroidGuard('lastBootDiagnostic')) return null;
    try {
      final raw = await PatcherChannel.lastBootDiagnostic();
      if (raw == null) return null;
      return PatchBootDiagnostic.fromNative(raw);
    } catch (e, s) {
      _log('lastBootDiagnostic failed: $e', s);
      return null;
    }
  }

  static Duration _verifyAfter = const Duration(seconds: 5);

  static void _installBootErrorCatchers() {
    final priorPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _maybeReportBootError(error, stack);
      return priorPlatformHandler?.call(error, stack) ?? false;
    };

    final priorFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _maybeReportBootError(details.exception, details.stack);
      (priorFlutterHandler ?? FlutterError.presentError).call(details);
    };
  }

  static void _maybeReportBootError(Object error, StackTrace? stack) {
    if (!_dartHookActive) return;
    if (_bootErrorReported) return;
    _bootErrorReported = true;
    final msg = error.toString();
    _log('boot-phase Dart error captured: $msg', stack);
    PatcherChannel.reportDartBootError(msg).catchError((e) {
      _log('reportDartBootError channel call failed: $e');
    });
  }

  static void _log(String msg, [StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('[FlutterPatcher] $msg');
    }
  }
}

/// Plugin-wide exception. Wraps network/parsing errors from [FlutterPatcher.checkUpdate].
class PatcherException implements Exception {
  final String message;
  PatcherException(this.message);
  @override
  String toString() => 'PatcherException: $message';
}

class _BootVerifier with WidgetsBindingObserver {
  static _BootVerifier? _instance;

  Duration _foregroundElapsed = Duration.zero;
  DateTime? _resumedAt;
  Timer? _timer;
  bool _windowClosed = false;

  static void start() {
    if (_instance != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _instance ??= _BootVerifier().._begin();
    });
  }

  void _begin() {
    FlutterPatcher.reportBootSuccess();

    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      _resumedAt = DateTime.now();
      _scheduleCheck();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_windowClosed) return;
    if (state == AppLifecycleState.resumed) {
      _resumedAt = DateTime.now();
      _scheduleCheck();
    } else {
      if (_resumedAt != null) {
        _foregroundElapsed += DateTime.now().difference(_resumedAt!);
        _resumedAt = null;
      }
      _timer?.cancel();
    }
  }

  void _scheduleCheck() {
    final remaining = FlutterPatcher._verifyAfter - _foregroundElapsed;
    _timer?.cancel();
    if (remaining <= Duration.zero) {
      _closeHookWindow();
      return;
    }
    _timer = Timer(remaining, _closeHookWindow);
  }

  void _closeHookWindow() {
    if (_windowClosed) return;
    _windowClosed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    FlutterPatcher._dartHookActive = false;
  }
}
