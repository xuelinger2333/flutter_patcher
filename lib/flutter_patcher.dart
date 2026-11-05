import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel, PlatformException;
import 'package:flutter/widgets.dart';

import 'src/blacklist.dart';
import 'src/boot_diagnostic.dart';
import 'src/io_stub.dart' if (dart.library.io) 'src/io.dart' as platform_io;
import 'src/patch_info.dart';
import 'src/patcher_channel.dart';
import 'src/publication_scope.dart';
import 'src/signed_manifest.dart';

export 'src/blacklist.dart';
export 'src/boot_diagnostic.dart';
export 'src/patch_info.dart';
export 'src/signed_manifest.dart';

/// Flutter hot-update entrypoint for Android and iOS.
///
/// `flutter_patcher` installs signed patches on hosts built with
/// `flutter_patcher build android|ios`, and loads them on the next cold start. SO and bytecode hosts share this API; iOS hosts are bytecode only.
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

  static Future<Map<String, String>>? _scope;

  /// The scope this host was built for; [checkUpdate] derives its manifest
  /// name from it.
  static Future<Map<String, String>> _hostScope() => _scope ??= PatcherChannel
      .channel
      .invokeMapMethod<String, String>('hostScope')
      .then(
        (scope) =>
            scope ?? (throw PatcherException('This host has no host policy')),
      );

  static Future<String?>? _url;

  /// Where `build` was told this host downloads patches: `url` in
  /// flutter_patcher.yaml, or serve's address when it is not set.
  static Future<String?> _hostUrl() =>
      _url ??= PatcherChannel.channel.invokeMethod<String>('hostUrl');

  /// Fetch an untrusted envelope, preserving its exact signed representation.
  /// Authentication and replay checks occur only in [applySignedManifest].
  static Future<SignedManifest> fetchSignedManifest(String url) async =>
      SignedManifest.parse(
        await platform_io.getSignedWire(url) ??
            (throw const FormatException('No signed manifest published')),
      );

  /// Authenticate, download and commit a publication, or persist a withdrawal.
  /// Requires a host built with `flutter_patcher build`.
  ///
  /// A publication needs its patch: [payload] when the app fetched it itself,
  /// for example from its own server, or else [baseUrl], the store URL the
  /// manifest's relative patch path is resolved against. Native code checks
  /// the patch against the signed manifest either way.
  static Future<SignedUpdateResult> applySignedManifest(
    SignedManifest manifest, {
    String? baseUrl,
    List<int>? payload,
  }) async {
    String? file;
    final fields = manifest.fields;
    if (fields['action'] == 'publish') {
      if (payload != null) {
        file = await platform_io.writePayload(payload);
      } else {
        if (baseUrl == null) {
          throw ArgumentError('Pass baseUrl or payload for a publication');
        }
        final size = int.parse(fields['size']!);
        _downloads.add(
          PatchApplyProgress(
            phase: PatchApplyPhase.downloading,
            totalBytes: size,
          ),
        );
        file = await platform_io.downloadPayload(
          '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/${fields['path']}',
          size,
          (received) => _downloads.add(
            PatchApplyProgress(
              phase: PatchApplyPhase.downloading,
              bytesReceived: received,
              totalBytes: size,
            ),
          ),
        );
      }
    }
    try {
      final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
        'applySignedManifest',
        {'wire': manifest.wire, 'payload': file},
      );
      if (raw == null) throw StateError('Missing authenticated update result');
      return SignedUpdateResult(
        raw['action'] as String,
        PatchApplyResult.fromNative(raw),
      );
    } finally {
      if (file != null) await platform_io.deletePayload(file);
    }
  }

  /// Apply an independent root-signed key-set update. The carrier is untrusted;
  /// native checks its domain, scope, root signature and durable trust revision.
  static Future<void> updatePublicationTrust(SignedManifest document) async {
    await PatcherChannel.channel.invokeMethod<Object?>(
      'updatePublicationTrust',
      {'wire': document.wire},
    );
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
    if (platform_io.isSupported) return false;
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

  /// Checks the store `flutter_patcher publish` writes, served at [url]; by
  /// default the address `build` wrote into the app: `url` in
  /// flutter_patcher.yaml, or `http://127.0.0.1:8686`, where
  /// `flutter_patcher serve` offers patches while developing. The host reads its own
  /// `manifests/<scope>.json` there and verifies it natively without
  /// persisting it. Only a manifest that would change the accepted state is
  /// an update; pass its [PatchInfo] to [applyPatch]. Nothing published yet
  /// is no update.
  ///
  /// To deliver manifests and patches some other way, pass them to
  /// [applySignedManifest] instead.
  ///
  /// Throws [PatcherException] on a host built without a host policy.
  static Future<PatchCheckResult> checkUpdate({
    String? url,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_unsupportedGuard('checkUpdate')) {
      return PatchCheckResult.none();
    }

    try {
      if (await _hostStrategy() == null) {
        throw PatcherException(
          'This app was not built with flutter_patcher; '
          'build it with dart run flutter_patcher build android|ios',
        );
      }
      final address =
          url ??
          await _hostUrl() ??
          (throw PatcherException(
            'This app has no update address; rebuild it with this version '
            'of flutter_patcher, or pass url to checkUpdate',
          ));
      return await _checkSigned(address, timeout);
    } on PatcherException {
      rethrow;
    } catch (e, s) {
      _log('checkUpdate failed: $e', s);
      throw PatcherException(e.toString());
    }
  }

  static Future<PatchCheckResult> _checkSigned(
    String url,
    Duration timeout,
  ) async {
    final base = url.replaceFirst(RegExp(r'/+$'), '');
    final wire = await platform_io.getSignedWire(
      '$base/manifests/${scopeOf(await _hostScope())}.json',
      timeout: timeout,
    );
    if (wire == null) return PatchCheckResult.none();
    final manifest = SignedManifest.parse(wire);
    final raw = await PatcherChannel.channel.invokeMapMethod<String, dynamic>(
      'checkSignedManifest',
      {'wire': manifest.wire},
    );
    if (raw == null || raw['fresh'] != true) return PatchCheckResult.none();
    return PatchCheckResult(
      hasUpdate: true,
      patch: PatchInfo(
        version: raw['patch_seq'] as String? ?? raw['action'] as String,
        raw: {
          'signed_manifest': manifest.wire,
          'action': raw['action'],
          'base_url': base,
        },
      ),
    );
  }

  /// Applies the update [checkUpdate] returned: downloads the patch the signed
  /// manifest names, then native code re-verifies the manifest, checks the
  /// patch's digest, signature, host fingerprint and sequence, and commits it
  /// for the next cold start. A withdrawal removes the installed patch instead.
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
    StreamSubscription<PatchApplyProgress>? sub;
    if (onProgress != null) {
      sub = applyProgress.listen(onProgress);
    }
    try {
      final wire = patchInfo.raw['signed_manifest'];
      if (wire is! String) {
        return PatchApplyResult.failure(
          PatchApplyError.invalidArgs,
          'Pass the PatchInfo returned by checkUpdate',
        );
      }
      return (await applySignedManifest(
        SignedManifest.parse(wire),
        baseUrl: patchInfo.raw['base_url'] as String?,
      )).result;
    } on platform_io.PayloadDownloadException catch (e) {
      return PatchApplyResult.failure(PatchApplyError.network, e.toString());
    } on PlatformException catch (e) {
      return PatchApplyResult.failure(PatchApplyError.unknown, e.message);
    } catch (e, s) {
      _log('applyPatch failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
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
