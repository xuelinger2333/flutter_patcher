import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel, PlatformException;
import 'package:flutter/widgets.dart';

import 'src/blacklist.dart';
import 'src/boot_diagnostic.dart';
import 'src/io_stub.dart' if (dart.library.io) 'src/io.dart' as platform_io;
import 'src/patch_file.dart';
import 'src/patch_info.dart';
import 'src/patcher_channel.dart';

export 'src/blacklist.dart';
export 'src/boot_diagnostic.dart';
export 'src/patch_info.dart';

/// Flutter hot-update entrypoint for Android and iOS.
///
/// `flutter_patcher` installs patch files on hosts built with
/// `flutter_patcher build android|ios`, and loads them on the next cold start.
/// SO and bytecode hosts share this API; iOS hosts are bytecode only.
///
/// Main APIs:
///
/// - [init]: configure crash protection and first-frame boot verification.
/// - [applyPatchBytes] / [applyPatchFile]: install a patch file the app
///   obtained in any way, such as from its own server; [patchTarget] names
///   the file this host needs.
/// - [checkUpdate] and [applyPatch]: a built-in downloader for patch files
///   placed at a URL.
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

  static Future<String?>? _url;

  /// Where `build` was told this host downloads patches: `url` in
  /// flutter_patcher.yaml, or serve's address when it is not set.
  static Future<String?> _hostUrl() =>
      _url ??= PatcherChannel.channel.invokeMethod<String>('hostUrl');

  /// Lets tests on a desktop host call the API as on a device.
  @visibleForTesting
  static bool debugAssumeSupported = false;

  /// Throws when this app was not built with `flutter_patcher build`.
  static Future<void> _requireHost() async {
    if (await _hostStrategy() == null) {
      throw PatcherException(
        'This app was not built with flutter_patcher; '
        'build it with dart run flutter_patcher build android|ios',
      );
    }
  }

  /// Who this host is: the patch [PatchTarget.fileName] it installs, its
  /// build and the sequence it accepted last. An app that fetches patch
  /// files itself sends these to its server to pick the right file.
  ///
  /// Throws [PatcherException] on an app not built with flutter_patcher.
  static Future<PatchTarget> get patchTarget async {
    if (_unsupportedGuard('patchTarget')) {
      throw PatcherException('patchTarget requires Android or iOS');
    }
    final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
      'patchTarget',
    );
    if (raw == null) {
      await _requireHost();
      throw PatcherException('This host has no host policy');
    }
    return PatchTarget.fromNative(raw);
  }

  /// Whether a patch file starting with [header], its first 146 bytes or
  /// more, is new to this host, before downloading the rest. Installing the
  /// file still verifies all of it.
  static Future<PatchInspection> inspectPatch(List<int> header) async {
    if (_unsupportedGuard('inspectPatch')) {
      throw PatcherException('inspectPatch requires Android or iOS');
    }
    final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
      'inspectPatch',
      {
        'header': Uint8List.fromList(
          header.length > patchHeaderSize
              ? header.sublist(0, patchHeaderSize)
              : header,
        ),
      },
    );
    return PatchInspection.fromNative(raw!);
  }

  /// Installs the patch file [bytes], or applies the withdrawal it is, for
  /// the next cold start. Native code verifies the whole file: that it is
  /// this host's, intact, signed when the host trusts a key, and numbered
  /// above every file the host accepted.
  static Future<PatchApplyResult> applyPatchBytes(List<int> bytes) async {
    if (_unsupportedGuard('applyPatchBytes')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${platform_io.operatingSystem}',
      );
    }
    final path = await platform_io.writePayload(bytes);
    try {
      return await applyPatchFile(path);
    } finally {
      await platform_io.deletePayload(path);
    }
  }

  /// Installs the patch file at [path] as [applyPatchBytes] does. The file
  /// stays where it is.
  static Future<PatchApplyResult> applyPatchFile(String path) async {
    if (_unsupportedGuard('applyPatchFile')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${platform_io.operatingSystem}',
      );
    }
    try {
      final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
        'applyPatchFile',
        {'path': path},
      );
      return PatchApplyResult.fromNative(raw);
    } on PlatformException catch (e) {
      return PatchApplyResult.failure(PatchApplyError.unknown, e.message);
    }
  }

  static bool _inited = false;
  static bool _bootErrorReported = false;
  static bool _unsupportedWarned = false;

  /// Whether Dart boot-error hooks can still report failures to native crash
  /// protection. The first frame clears native boot state immediately; this
  /// flag keeps Dart-side blank-screen detection alive for [init]'s
  /// `verifyAfter` window.
  static bool _dartHookActive = true;

  static bool _unsupportedGuard(String method) {
    if (platform_io.isSupported || debugAssumeSupported) return false;
    if (!_unsupportedWarned) {
      _unsupportedWarned = true;
      debugPrint(
        '[FlutterPatcher] WARNING: $method called on ${platform_io.operatingSystem}. '
        'This plugin supports Android and iOS only; all calls are no-ops. '
        'See README > What Can Be Patched?',
      );
    }
    return true;
  }

  static const EventChannel _eventChannel = EventChannel(
    'flutter_patcher/events',
  );
  static Stream<PatchApplyProgress>? _progressStream;

  /// Dart downloads the patch; native code verifies and installs it.
  static final _downloads = StreamController<PatchApplyProgress>.broadcast();

  /// Broadcast progress stream for [applyPatch].
  ///
  /// Subscribe before calling [applyPatch] to receive `downloading`,
  /// `verifying`, and `finalizing` events. Unsupported platforms return an
  /// empty stream.
  static Stream<PatchApplyProgress> get applyProgress {
    if (_unsupportedGuard('applyProgress')) return const Stream.empty();
    return _progressStream ??= () {
      final subscriptions = <StreamSubscription<PatchApplyProgress>>[];
      late final StreamController<PatchApplyProgress> merged;
      merged = StreamController<PatchApplyProgress>.broadcast(
        onListen: () {
          subscriptions
            ..add(_downloads.stream.listen(merged.add))
            ..add(
              _eventChannel
                  .receiveBroadcastStream()
                  .map((raw) => PatchApplyProgress.fromNative(raw))
                  .listen(merged.add, onError: merged.addError),
            );
        },
        onCancel: () {
          for (final subscription in subscriptions) {
            subscription.cancel();
          }
          subscriptions.clear();
        },
      );
      return merged.stream;
    }();
  }

  /// Configures crash protection. A patched start is confirmed natively at
  /// its first frame; uncaught Dart errors still count as a failed start for
  /// [verifyAfter] after it.
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
    if (_unsupportedGuard('init')) return;
    if (_inited) return;
    _inited = true;
    _verifyAfter = verifyAfter;

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

  /// Checks for a patch file at [url]: `GET <url>/<fileName>`, where
  /// `fileName` is this host's [PatchTarget.fileName] and the file is what
  /// `flutter_patcher patch` or `publish` wrote. By default [url] is the
  /// address `build` wrote into the app: `url` in `flutter_patcher.yaml`, or
  /// `http://127.0.0.1:8686`, where `flutter_patcher serve` offers patches
  /// while developing.
  ///
  /// Only the first 146 bytes are read; a file is an update when it is new
  /// to this host (see [inspectPatch]). No file there is no update. Pass the
  /// [PatchInfo] to [applyPatch].
  ///
  /// This is one way to deliver patch files; an app that fetches them
  /// itself passes them to [applyPatchBytes] instead.
  ///
  /// Throws [PatcherException] on a host built without a host policy, when
  /// no address is given and the app has none, and when the check fails.
  static Future<PatchCheckResult> checkUpdate({
    String? url,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_unsupportedGuard('checkUpdate')) {
      return PatchCheckResult.none();
    }

    try {
      await _requireHost();
      final address =
          url ??
          await _hostUrl() ??
          (throw PatcherException(
            'This app has no update address; rebuild it with this version '
            'of flutter_patcher, or pass url to checkUpdate',
          ));
      final target = await patchTarget;
      final file =
          '${address.replaceFirst(RegExp(r'/+$'), '')}/${target.fileName}';
      final header = await platform_io.readPatchHeader(file, timeout: timeout);
      if (header == null) return PatchCheckResult.none();
      final inspection = await inspectPatch(header);
      if (!inspection.fresh) return PatchCheckResult.none();
      return PatchCheckResult(
        hasUpdate: true,
        patch: PatchInfo(
          version: '${inspection.seq}',
          raw: {
            'url': file,
            'seq': inspection.seq,
            'action': inspection.action,
            'size': PatchHeader.parse(header).fileLength,
          },
        ),
      );
    } on PatcherException {
      rethrow;
    } catch (e, s) {
      _log('checkUpdate failed: $e', s);
      throw PatcherException(e.toString());
    }
  }

  /// Applies the update [checkUpdate] returned: downloads the patch file,
  /// then native code verifies and installs it for the next cold start, as
  /// [applyPatchBytes] does. A withdrawal removes the installed patch.
  ///
  /// Returns a [PatchApplyResult]. `ok=true` means the patch is installed and
  /// will take effect on the next cold start.
  static Future<PatchApplyResult> applyPatch(
    PatchInfo patchInfo, {
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_unsupportedGuard('applyPatch')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${platform_io.operatingSystem}',
      );
    }
    final url = patchInfo.raw['url'], size = patchInfo.raw['size'];
    if (url is! String || size is! int) {
      return PatchApplyResult.failure(
        PatchApplyError.invalidArgs,
        'Pass the PatchInfo returned by checkUpdate',
      );
    }
    StreamSubscription<PatchApplyProgress>? sub;
    if (onProgress != null) {
      sub = applyProgress.listen(onProgress);
    }
    String? path;
    try {
      _downloads.add(
        PatchApplyProgress(
          phase: PatchApplyPhase.downloading,
          totalBytes: size,
        ),
      );
      path = await platform_io.downloadPayload(
        url,
        size,
        (received) => _downloads.add(
          PatchApplyProgress(
            phase: PatchApplyPhase.downloading,
            bytesReceived: received,
            totalBytes: size,
          ),
        ),
      );
      return await applyPatchFile(path);
    } on platform_io.PayloadDownloadException catch (e) {
      return PatchApplyResult.failure(PatchApplyError.network, e.toString());
    } catch (e, s) {
      _log('applyPatch failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
      if (path != null) await platform_io.deletePayload(path);
      await sub?.cancel();
    }
  }

  /// Deletes the current patch. The next cold start runs the app's built-in
  /// version. Manual rollback does not blacklist the patch.
  static Future<void> rollback() async {
    if (_unsupportedGuard('rollback')) return;
    try {
      await PatcherChannel.rollback();
    } catch (e, s) {
      _log('rollback failed: $e', s);
    }
  }

  /// Host build number: Android versionCode, iOS CFBundleVersion. Returns null
  /// on failure or an unsupported platform.
  static Future<int?> get appVersionCode async {
    if (_unsupportedGuard('appVersionCode')) return null;
    try {
      return await PatcherChannel.appVersionCode();
    } catch (_) {
      return null;
    }
  }

  /// Current device ABI (`arm64-v8a`, `ios-arm64`). Useful when your backend
  /// routes patches per ABI.
  static Future<String> get deviceAbi async {
    if (_unsupportedGuard('deviceAbi')) return '';
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
    if (_unsupportedGuard('currentVersion')) return null;
    try {
      final v = await PatcherChannel.currentVersion();
      if (v == null || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Local bad-patch blacklist: patches whose starts failed `maxCrashCount`
  /// times (see [init]).
  static Future<List<BlacklistEntry>> get blacklist async {
    if (_unsupportedGuard('blacklist')) return const [];
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
    if (_unsupportedGuard('clearBlacklist')) return;
    try {
      await PatcherChannel.clearBlacklist();
    } catch (e, s) {
      _log('clearBlacklist failed: $e', s);
    }
  }

  /// Last cold-start patch loading diagnostic.
  ///
  /// `applyPatch` reports install-time failures. This getter reports what
  /// happened on the next cold start: version mismatch, a failed start,
  /// crash rollback, loader hook failure, or successful patch load. A start
  /// that loaded a patch is recorded at its first frame; asked earlier, the
  /// getter completes then, with this start's record.
  static Future<PatchBootDiagnostic?> get lastBootDiagnostic async {
    if (_unsupportedGuard('lastBootDiagnostic')) return null;
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

/// Plugin-wide exception. Wraps network and parsing errors from
/// [FlutterPatcher.checkUpdate] and calls on an app that cannot be patched.
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
