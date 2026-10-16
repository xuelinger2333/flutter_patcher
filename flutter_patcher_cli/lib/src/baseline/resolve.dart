import 'package:path/path.dart' as p;
import '../core.dart';
import 'manifest.dart';
import 'repository.dart';
import 'split.dart';

/// One release slot resolved to the directories patch compilation reads.
class ResolvedRelease {
  /// `release` (schema 5), `legacy` (sidecar) or `legacy_fingerprint`
  /// (legacy baseline addressed by fingerprint alone).
  final String format;
  final String flavor, versionCode, abi, fingerprint, compileRoot, releaseRoot;

  /// Compile manifest, or the whole legacy manifest.
  final Map<String, dynamic> compile;

  /// release_receipt.json, or the legacy build_receipt.json (empty for
  /// schema 1).
  final Map<String, dynamic> receipt;

  /// Schema 5 view of a legacy schema 2–4 baseline.
  final SplitBaseline? projection;
  final Map<String, dynamic>? link;
  final Map<String, dynamic>? _release;

  /// Non-fatal findings, e.g. an unreadable legacy sidecar beside a release.
  final List<String> warnings = [];
  ResolvedRelease(
      {required this.format,
      required this.flavor,
      required this.versionCode,
      required this.abi,
      required this.fingerprint,
      required this.compileRoot,
      required this.releaseRoot,
      required this.compile,
      required this.receipt,
      Map<String, dynamic>? release,
      this.projection,
      this.link})
      // Addressed by fingerprint alone, the release is unknown: such patches
      // stay unpinned, as before release binding existed.
      : _release = format == 'legacy_fingerprint'
            ? null
            : release ?? projection?.release;
  bool get legacy => format != 'release';
  String get slot => releaseSlot(flavor, versionCode, abi);

  /// Null for a schema 1 baseline or a release addressed by fingerprint.
  Map<String, dynamic>? get release => _release;
  String get buildId => (_release ?? compile)['build_id'] as String;
  String? get releaseSha => _release == null ? null : manifestDigest(_release);
  Map<String, dynamic>? get target =>
      _release == null ? null : releaseTarget(_release);
  Map<String, dynamic> get report => {
        'flavor': flavor,
        'version_code': versionCode,
        'abi': abi,
        'format': format,
        'release_manifest_sha256': releaseSha,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

extension ReleaseResolution on BaselineRepository {
  /// Resolution order: schema 5 release (verified against the store when one
  /// is configured), legacy sidecar, then — only with [expectedFingerprint] —
  /// a legacy baseline by fingerprint. An equivalent legacy sidecar wins over
  /// a schema 5 release, so publication keeps the legacy identity shape.
  Future<ResolvedRelease> resolve(String flavor, String versionCode,
      {String abi = 'arm64-v8a',
      String? expectedFingerprint,
      String? sdkRoot}) async {
    final slot = releaseSlot(flavor, versionCode, abi);
    final v5 = await _v5(flavor, versionCode, abi, sdkRoot);
    final sidecarFile = await _sidecar(flavor, versionCode, abi);
    ResolvedRelease? legacy;
    final warnings = <String>[];
    if (sidecarFile != null && v5 == null) {
      legacy = await _fromSidecar(sidecarFile, flavor, versionCode, abi,
          sdkRoot: sdkRoot);
    } else if (sidecarFile != null) {
      // A sidecar that cannot be read cannot contradict a valid release.
      try {
        legacy = await _fromSidecar(sidecarFile, flavor, versionCode, abi);
      } on Failure catch (e) {
        warnings.add(
            'Ignored unreadable legacy sidecar ${sidecarName(flavor, versionCode, abi)} (${e.code}: ${e.message})');
      }
      require(
          legacy == null || legacy.releaseSha == v5!.releaseSha,
          'BASELINE_RELEASE_AMBIGUOUS',
          'A legacy sidecar and a schema 5 release both bind release-$slot with different content; remove one of them from the store.');
      if (legacy != null && sdkRoot != null) {
        await verifyPlatform(legacy.compile, sdkRoot);
      }
    }
    final chosen = legacy ??
        v5 ??
        (expectedFingerprint == null
            ? throw Failure('BASELINE_NOT_FOUND',
                'No archived release-$slot; check --flavor/--version-code, or pass --fingerprint for a legacy baseline.')
            : await _legacy(expectedFingerprint, flavor, versionCode, abi,
                sdkRoot: sdkRoot));
    require(
        expectedFingerprint == null ||
            chosen.fingerprint == expectedFingerprint,
        'BASELINE_FINGERPRINT_MISMATCH',
        'release-$slot was built from fingerprint ${chosen.fingerprint}, not the requested one.');
    chosen.warnings.addAll(warnings);
    return chosen;
  }

  Future<ResolvedRelease?> _v5(
      String flavor, String versionCode, String abi, String? sdkRoot) async {
    final root = await fetchReleaseObject(flavor, versionCode, abi);
    if (root == null) return null;
    final ref = (await verifyReleaseObject(root))['compile'] as Map;
    final fp = ref['fingerprint'] as String;
    final compileRoot = await fetchCompile(fp,
        sdkRoot: sdkRoot, manifestSha: ref['manifest_sha256'] as String);
    final compile =
        await verifyCompile(compileRoot, expected: fp, sdkRoot: sdkRoot);
    return ResolvedRelease(
        format: 'release',
        flavor: flavor,
        versionCode: versionCode,
        abi: abi,
        fingerprint: fp,
        compileRoot: compileRoot,
        releaseRoot: root,
        compile: compile,
        release: await verifyReleaseObject(root,
            compile: compile, compileRoot: compileRoot),
        receipt: await baselineObject(p.join(root, 'release_receipt.json')));
  }

  /// The downloaded legacy sidecar of a slot; null without one or offline.
  Future<String?> _sidecar(
      String flavor, String versionCode, String abi) async {
    if (store == null) return null;
    final name = sidecarName(flavor, versionCode, abi);
    final file = p.join(await work(), name);
    return await lookup(name, file) ? file : null;
  }

  /// The legacy sidecar binding of a slot; null when the store has none.
  Future<ResolvedRelease?> legacySlot(
      String flavor, String versionCode, String abi,
      {String? sdkRoot}) async {
    final file = await _sidecar(flavor, versionCode, abi);
    return file == null
        ? null
        : _fromSidecar(file, flavor, versionCode, abi, sdkRoot: sdkRoot);
  }

  Future<ResolvedRelease> _fromSidecar(
      String file, String flavor, String versionCode, String abi,
      {String? sdkRoot}) async {
    final link = await baselineObject(file);
    valid(baselineHash.hasMatch('${link['fingerprint']}'),
        'Invalid sidecar fingerprint.');
    return _legacy(link['fingerprint'] as String, flavor, versionCode, abi,
        sdkRoot: sdkRoot, link: link);
  }

  Future<ResolvedRelease> _legacy(
      String fp, String flavor, String versionCode, String abi,
      {String? sdkRoot, Map<String, dynamic>? link}) async {
    final root = await fetch(fp, sdkRoot: sdkRoot);
    final manifest = await verifyBaseline(root, expected: fp, sdkRoot: sdkRoot);
    if (link != null) {
      valid(canonical(link) == canonical(sidecar(manifest)),
          'Release sidecar binding mismatch.');
    }
    final split = [2, 3, 4].contains(manifest['schema']);
    final receipt = split
        ? await baselineObject(p.join(root, 'build_receipt.json'))
        : <String, dynamic>{};
    return ResolvedRelease(
        format: link == null ? 'legacy_fingerprint' : 'legacy',
        flavor: flavor,
        versionCode: versionCode,
        abi: abi,
        fingerprint: fp,
        compileRoot: root,
        releaseRoot: root,
        compile: manifest,
        receipt: receipt,
        projection: split
            ? splitBaseline(manifest, receipt,
                flavor: flavor, versionCode: versionCode, abi: abi)
            : null,
        link: link);
  }

  /// The release binding of a slot in either format. Legacy slots return the
  /// sidecar unchanged; schema 5 slots return the same identity keys.
  Future<Map<String, dynamic>> verifyRelease(String flavor, String versionCode,
      {String abi = 'arm64-v8a', String? sdkRoot}) async {
    final r = await resolve(flavor, versionCode, abi: abi, sdkRoot: sdkRoot);
    require(r.compile['runtime_bootstrap'] != false, 'BASELINE_NOT_RELEASE',
        'Pipeline validation baseline has no runtime bootstrap and is not a release.');
    if (r.link != null) return r.link!;
    final warnings = r.warnings;
    return {
      'schema': 5,
      'fingerprint': r.fingerprint,
      'flutter_version': r.compile['flutter_version'],
      'engine_commit': r.compile['engine_commit'],
      'build_id': r.buildId,
      'libapp_sha256': r.receipt['libapp_sha256'],
      'runtime_bootstrap': r.compile['runtime_bootstrap'],
      for (final k in ['host_policy_sha256', 'framework_partition_sha256'])
        if (r.compile.containsKey(k)) k: r.compile[k],
      'release': 'release-${r.slot}.tar.zst',
      'release_manifest_sha256': r.releaseSha,
      'compile_manifest_sha256': manifestDigest(r.compile),
      if (warnings.isNotEmpty) 'warnings': warnings,
    };
  }

  /// Re-verifies resolved directories, e.g. after a long compilation.
  Future<void> recheck(ResolvedRelease r, {String? sdkRoot}) async {
    if (r.legacy) {
      await verifyBaseline(r.compileRoot,
          expected: r.fingerprint, sdkRoot: sdkRoot);
      return;
    }
    final compile = await verifyCompile(r.compileRoot,
        expected: r.fingerprint, sdkRoot: sdkRoot);
    final release = await verifyReleaseObject(r.releaseRoot,
        compile: compile, compileRoot: r.compileRoot);
    valid(canonical(release) == canonical(r.release),
        'Release baseline changed while in use.');
  }
}
