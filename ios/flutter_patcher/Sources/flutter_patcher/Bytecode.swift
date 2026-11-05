import Foundation

/// FPTC v1: never allocate from the unauthenticated payload length.
enum BytecodeEnvelope {
  static let maxBytes = 320 * 1024 * 1024
  /// Header fields and Ed25519 signature before the signed payload.
  static let header = 146

  /// A verified header pins its payload by digest, so the digest of the
  /// header kept at install pins the whole file the authorization named.
  static func headerDigest(_ bytes: Data) -> String { sha256Hex(bytes.prefix(header)) }

  /// True when verified [bytes] are the file [meta] names; older candidates compare the file's digest.
  static func identifies(_ bytes: Data, _ meta: CandidateStore.Meta) -> Bool {
    if let digest = meta["header_sha256"] as? String { return headerDigest(bytes) == digest }
    return sha256Hex(bytes) == meta["sha256"] as? String
  }

  private static func uint(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<count { value = value << 8 | UInt64(bytes[bytes.startIndex + offset + i]) }
    return value
  }

  private static func slice(_ bytes: Data, _ from: Int, _ to: Int) -> Data {
    bytes.subdata(in: bytes.startIndex + from..<bytes.startIndex + to)
  }

  static func verify(_ bytes: Data, fingerprint: String, rawKey: Data) throws -> Int64 {
    try require((146...maxBytes).contains(bytes.count), "Envelope size")
    try require(uint(bytes, 42, 8) == UInt64(bytes.count - 146), "Envelope length")
    try require(uint(bytes, 0, 4) == 0x4650_5443, "Envelope magic")
    try require(uint(bytes, 4, 2) == 1, "Envelope version")
    try require(hex(slice(bytes, 6, 38)) == fingerprint, "Envelope fingerprint")
    let body = slice(bytes, 146, bytes.count)
    try require(sha256Hex(body) == hex(slice(bytes, 50, 82)), "Envelope hash")
    try require(rawKey.count == 32, "Raw Ed25519 public key required")
    // Pure Ed25519 signs the header followed by the ZIP, not a prehash.
    try require(
      Ed25519.verify(key: rawKey, signature: slice(bytes, 82, 146), message: slice(bytes, 0, 82) + body),
      "Envelope signature")
    let seq = Int64(uint(bytes, 38, 4))
    try require(seq > 0, "Patch sequence")
    return seq
  }
}

/// Token-bound, idempotent startup settlement. A first frame never undoes failure.
final class BytecodeAttempt {
  let token: String
  private(set) var running = false
  private(set) var failed = false
  private var succeeded = false

  /// Started, and neither its first frame nor a failure has settled it.
  var unsettled: Bool { running && !succeeded && !failed }

  init(_ token: String) { self.token = token }

  func start(_ received: String?) -> Bool {
    guard received == token, !running, !failed else { return false }
    running = true
    return true
  }

  func succeed(_ received: String?) -> Bool {
    guard received == token, running, !failed, !succeeded else { return false }
    succeeded = true
    return true
  }

  func fail(_ received: String?) -> Bool {
    guard received == token, !failed else { return false }
    failed = true
    return true
  }
}

/// Authorization transactions; the caller holds the manager lock except while downloading.
final class AuthenticatedUpdates {
  /// Must equal the pubspec version (checked by test/channel_contract_test.dart).
  static let pluginVersion = "1.0.1"

  let host: HostTrustConfig
  private let store: ManifestStateStore

  init(host: HostTrustConfig) throws {
    try HostTrustConfig.requireOwner()
    self.host = host
    store = try ManifestStateStore(host: host)
  }

  private func decide(_ wire: String, _ state: ManifestStateStore.State) throws -> PublishManifest.Decision {
    try PublishManifest.verify(
      wire, trustedKeys: try store.keys(state), scope: host.scope, pluginVersion: Self.pluginVersion,
      state: state.manifest)
  }

  func accept(_ wire: String) throws -> PublishManifest.Decision {
    var state = try store.read()
    let decision = try decide(wire, state)
    state.manifest = decision.next
    try store.write(state)
    return decision
  }

  /// Verifies [wire] against the accepted state without persisting it.
  func verify(_ wire: String) throws -> PublishManifest.Decision { try decide(wire, try store.read()) }

  /// `fresh` when accepting [wire] would change the accepted state.
  func inspect(_ wire: String) throws -> [String: Any] {
    let state = try store.read()
    let decision = try decide(wire, state)
    return [
      "action": decision.action, "fresh": decision.next != state.manifest,
      "patch_seq": decision.fields["patch_seq"] ?? NSNull(),
    ]
  }

  func updateTrust(_ wire: String) throws {
    var state = try store.read()
    let update = try TrustUpdate.verify(
      wire, root: host.root, scope: host.scope, revision: state.trustRevision, previousHash: state.trustHash)
    state.trustWire = wire
    state.trustRevision = update.revision
    state.trustHash = update.hash
    try store.write(state)
  }

  func checkCommit(_ wire: String) throws -> PublishManifest.Decision {
    let state = try store.read()
    let decision = try decide(wire, state)
    try require(
      decision.action == "publish" && decision.next == state.manifest
        && Int64(decision.fields["patch_seq"]!)! > state.manifest.withdrawnThrough,
      "Authorization superseded")
    return decision
  }

  func checkBoot(_ meta: CandidateStore.Meta) throws {
    let state = try store.read()
    guard let authorization = meta["authorization"] as? String else { throw PatcherError("Candidate authorization") }
    let decision = try PublishManifest.verify(
      authorization, trustedKeys: try store.keys(state), scope: host.scope, pluginVersion: Self.pluginVersion,
      state: PublishManifest.State())
    let seq = Int64(decision.fields["patch_seq"] ?? "") ?? -1
    try require(
      decision.action == "publish" && decision.next.revision <= state.manifest.revision
        && decision.next.highSeq <= state.manifest.highSeq
        && (decision.next.revision != state.manifest.revision
          || decision.next.manifestHash == state.manifest.manifestHash)
        && seq > state.manifest.withdrawnThrough && seq == int64(meta["seq"])
        && decision.fields["sha256"] == meta["sha256"] as? String,
      "Candidate authorization withdrawn")
  }

  /// The payload Dart downloaded to [path]: the signed size and digest, then deleted.
  static func payload(_ fields: [String: String], path: String) throws -> Data {
    defer { try? FileManager.default.removeItem(atPath: path) }
    let expected = Int(fields["size"]!)!
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    try require(size == expected, "Payload size")
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    try require(bytes.count == expected && sha256Hex(bytes) == fields["sha256"], "Payload digest/size")
    return bytes
  }
}
typealias Progress = (_ phase: String, _ received: Int64, _ total: Int64) -> Void

/// Bytecode candidates of an authenticated host. All state changes hold [lock].
final class BytecodePatchManager {
  private static let lock = NSRecursiveLock()
  private static var processClaimed = false

  private(set) var bootstrapped = false
  private(set) var frameToken: String?

  /// Whether this start loaded a patch whose first frame is still to come.
  var awaitingFirstFrame: Bool {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return attempt?.unsettled == true
  }
  private var fingerprint: String?
  private var key: Data?
  private var offered: String?
  private var attempt: BytecodeAttempt?
  private var offeredMeta: CandidateStore.Meta?
  private var storeValue: CandidateStore?
  private var authValue: AuthenticatedUpdates??

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return try body()
  }

  private func store() throws -> CandidateStore {
    if let store = storeValue { return store }
    let store = try CandidateStore(strategy: "bytecode")
    storeValue = store
    return store
  }

  /// nil on a host without a bytecode policy.
  private func authenticated() throws -> AuthenticatedUpdates? {
    if let auth = authValue { return auth }
    let auth = try HostTrustConfig.load().map { try AuthenticatedUpdates(host: $0) }
    authValue = .some(auth)
    return auth
  }

  func announceBootstrap() { locked { bootstrapped = true } }

  func bootPayload(fingerprint fp: String, publicKey: String) throws -> [String: Any]? {
    try locked {
      let started = DispatchTime.now().uptimeNanoseconds
      let (auth, raw) = try bootstrap(fp, publicKey)
      if fingerprint != nil || Self.processClaimed { return nil }
      Self.processClaimed = true
      fingerprint = fp
      key = raw
      let store = try store()
      try store.recoverAttempt()
      guard let meta = try store.activeFor(fp) else {
        store.noPatch()
        return nil
      }
      do {
        try auth.checkBoot(meta)
        var reply = try offer(store, meta, fp, raw)
        let token = UUID().uuidString
        offered = token
        attempt = BytecodeAttempt(token)
        offeredMeta = meta
        // This exact verified snapshot goes to Dart; the file is never reopened.
        reply["transportVersion"] = 1
        reply["attempt"] = token
        reply["profile_us"] = ["total": (DispatchTime.now().uptimeNanoseconds - started) / 1000]
        return reply
      } catch {
        try store.recordFailure(meta, (error as? PatcherError)?.description ?? "Candidate rejected")
        return nil
      }
    }
  }

  /// The offer for an isolate a background engine starts, for any number of
  /// engines, starting no attempt and changing no boot state: the code this
  /// process booted, so one process never runs two versions; a failed boot
  /// runs as built. Before this process boots, the active, authorized
  /// candidate. nil runs the entry point as built.
  func backgroundPayload(fingerprint fp: String, publicKey: String) throws -> [String: Any]? {
    try locked {
      let (auth, raw) = try bootstrap(fp, publicKey)
      let store = try store()
      let claimed = fingerprint != nil || Self.processClaimed
      guard let meta = claimed ? (attempt?.failed == true ? nil : offeredMeta) : try store.activeFor(fp)
      else { return nil }
      do {
        try auth.checkBoot(meta)
        return try offer(store, meta, fp, raw).merging(["transportVersion": 1]) { $1 }
      } catch {
        // The candidate is the app isolate's to judge; this engine runs as built.
        NSLog("[FlutterPatcher] Background payload rejected: \(error)")
        return nil
      }
    }
  }

  private func bootstrap(_ fp: String, _ publicKey: String) throws -> (AuthenticatedUpdates, Data) {
    guard let auth = try authenticated() else { throw PatcherError("Bytecode requires a host policy") }
    let raw = Data(base64Encoded: publicKey)
    try require(fp == auth.host.scope["fingerprint"] && raw == auth.host.fptcKey,
      "Bootstrap differs from immutable host")
    return (auth, raw!)
  }

  /// [meta]'s stored envelope, verified, as offer fields; this exact snapshot goes to Dart.
  private func offer(_ store: CandidateStore, _ meta: CandidateStore.Meta, _ fp: String, _ raw: Data) throws
    -> [String: Any]
  {
    let bytes = try Storage.read(store.fileURL(meta), limit: BytecodeEnvelope.maxBytes)
    let seq = try BytecodeEnvelope.verify(bytes, fingerprint: fp, rawKey: raw)
    try require(seq == int64(meta["seq"]) && BytecodeEnvelope.identifies(bytes, meta), "Stored candidate changed")
    // The bootstrap reads the same ranges and skips only the CRCs and
    // digests checked here; see parseAuthenticatedPatchBytes.
    return ["envelopeBytes": bytes, "entries": try PatchArchive.readBytecode(bytes, fingerprint: fp, seq: seq)]
  }

  func markBooting(_ token: String?, foreground: Bool = true) throws -> Bool {
    try locked {
      guard let token = token, token == offered, attempt?.running != true, attempt?.failed != true,
            let meta = offeredMeta
      else { return false }
      do { try authenticated()?.checkBoot(meta) } catch { return false }
      let store = try store()
      // A rollback or a newly installed candidate invalidates a prepared offer.
      guard store.active().map({ store.id($0) == store.id(meta) }) == true else { return false }
      try store.markLoading(meta, foreground: foreground)
      let started = attempt?.start(token) == true
      if started { frameToken = token }
      return started
    }
  }

  /// The app left (or re-entered) the foreground; see CrashGuard.
  func foregroundChanged(_ foreground: Bool) throws {
    try locked {
      guard attempt?.running == true else { return }
      try foreground ? store().resumeLoading() : store().pauseLoading()
    }
  }

  func success(_ token: String?) throws {
    try locked {
      guard let token = token, attempt?.succeed(token) == true, let meta = offeredMeta else { return }
      try store().markSuccess(meta)
      try store().diagnostic(BootDiagnosticStore.patched, "Bytecode first frame", meta)
    }
  }

  func error(_ token: String?, message: String?, quarantine: Bool) throws {
    try locked {
      guard let token = token, token == offered else { return }
      if attempt?.fail(token) != true {
        // init() and bootstrap may report the same error in either order. A
        // later fatal report escalates disposition, never the crash count.
        if quarantine && attempt?.failed == true, let meta = offeredMeta {
          try store().recordFailure(meta, message ?? "Unsafe startup", quarantine: true, increment: false)
        }
        return
      }
      frameToken = nil
      if let meta = offeredMeta {
        try store().recordFailure(meta, message ?? "Dart boot failure", quarantine: quarantine)
      }
      try store().clearAttempt()
    }
  }

  /// Applies [wire] with the payload Dart downloaded to [payload]; a withdrawal has none.
  func applyManifest(_ wire: String, payload: String?, progress: Progress) throws -> [String: Any] {
    guard let auth = try locked({ try authenticated() }) else { throw PatcherError("Host has no authenticated policy") }
    let decision = try locked { try auth.verify(wire) }
    if decision.action == "withdraw" {
      try locked {
        _ = try auth.accept(wire)
        try invalidateUnauthorized(auth)
      }
      return ["action": "withdraw", "ok": true]
    }
    // Accept only an intact payload, so a failed download stays retryable.
    guard let payload = payload else { throw PatcherError("Payload required") }
    let bytes = try AuthenticatedUpdates.payload(decision.fields, path: payload)
    return try locked {
      _ = try auth.accept(wire)
      let fields = try auth.checkCommit(wire).fields
      var result = try install(fields, bytes: bytes, wire: wire, progress: progress)
      result["action"] = "publish"
      return result
    }
  }

  func inspect(_ wire: String) throws -> [String: Any] {
    try locked {
      guard let auth = try authenticated() else { throw PatcherError("Host has no authenticated policy") }
      return try auth.inspect(wire)
    }
  }

  func updateTrust(_ wire: String) throws {
    try locked {
      guard let auth = try authenticated() else { throw PatcherError("Host has no authenticated policy") }
      try auth.updateTrust(wire)
      try invalidateUnauthorized(auth)
    }
  }

  private func invalidateUnauthorized(_ auth: AuthenticatedUpdates) throws {
    guard let candidate = try store().active() else { return }
    if (try? auth.checkBoot(candidate)) == nil { try rollback() }
  }

  private static func failure(_ code: String, _ message: String) -> [String: Any] {
    ["ok": false, "error": code, "message": message]
  }

  /// Installs downloaded [bytes] that the signed manifest [wire] authorizes.
  private func install(_ fields: [String: String], bytes: Data, wire: String, progress: Progress) throws
    -> [String: Any]
  {
    guard let fingerprint = fingerprint, let key = key else {
      return Self.failure("SIGNATURE_INVALID", "A bootstrapped host is required")
    }
    let total = Int64(bytes.count)
    progress("verifying", total, total)
    let seq: Int64
    do { seq = try BytecodeEnvelope.verify(bytes, fingerprint: fingerprint, rawKey: key) } catch {
      return Self.failure("SIGNATURE_INVALID", "\(error)")
    }
    let hash = sha256Hex(bytes)
    do {
      try require(fields["sha256"] == hash && Int64(fields["patch_seq"] ?? "") == seq, "Manifest differs from payload")
      let store = try store()
      var meta = store.candidate(
        fingerprint: fingerprint, seq: seq, sha256: hash, version: fields["patch_seq"]!, authorization: wire)
      meta["header_sha256"] = BytecodeEnvelope.headerDigest(bytes)
      if store.isBlacklisted(meta) { return Self.failure("BLACKLISTED", "Bytecode candidate is blacklisted") }
      try store.requireNewer(meta)
      progress("finalizing", total, total)
      try store.save(meta, bytes: bytes)
      return ["ok": true, "error": NSNull(), "message": NSNull()]
    } catch let error as PatcherError {
      return Self.failure("INVALID_ARGS", error.description)
    } catch {
      return Self.failure("IO_ERROR", "\(error)")
    }
  }

  func rollback() throws {
    try locked {
      if try authenticated() != nil { try HostTrustConfig.requireOwner() }
      try store().clearActive()
      offered = nil
      attempt = nil
      frameToken = nil
    }
  }

  func currentVersion() throws -> String? { try locked { try store().active()?["version"] as? String } }

  func blacklist() throws -> [[String: Any]] { try locked { try store().blacklist() } }

  func clearBlacklist() throws {
    try locked {
      if try authenticated() != nil { try HostTrustConfig.requireOwner() }
      try store().clearBlacklist()
    }
  }
}
