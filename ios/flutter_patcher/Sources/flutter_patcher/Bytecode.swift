import Foundation

/// FPTC v1, the whole patch file: never allocate from the unauthenticated
/// payload length. A file with no payload is a withdrawal.
enum BytecodeEnvelope {
  static let maxBytes = 320 * 1024 * 1024
  /// Header fields and Ed25519 signature before the payload.
  static let header = 146

  /// What a header claims, before anything is verified.
  struct Header: Equatable {
    let fingerprint: String
    let seq: Int64
    let length: UInt64
    var withdrawal: Bool { length == 0 }
  }

  /// A verified header pins its payload by digest, so the digest of the
  /// header kept at install pins the whole installed file.
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

  /// Reads the first [header] bytes of [bytes]: magic, version and a nonzero sequence.
  static func readHeader(_ bytes: Data) throws -> Header {
    try require(bytes.count >= header, "Envelope size")
    try require(uint(bytes, 0, 4) == 0x4650_5443, "Envelope magic")
    try require(uint(bytes, 4, 2) == 1, "Envelope version")
    let seq = Int64(uint(bytes, 38, 4))
    try require(seq > 0, "Patch sequence")
    let length = uint(bytes, 42, 8)
    try require(length <= UInt64(maxBytes - header), "Envelope length")
    return Header(fingerprint: hex(slice(bytes, 6, 38)), seq: seq, length: length)
  }

  /// The whole file of [fingerprint]'s host: its header, length and digest,
  /// and when the host trusts [rawKey], the Ed25519 signature over the
  /// header followed by the payload. Returns its header.
  static func verify(_ bytes: Data, fingerprint: String, rawKey: Data?) throws -> Header {
    try require((header...maxBytes).contains(bytes.count), "Envelope size")
    let read = try readHeader(bytes)
    try require(read.length == UInt64(bytes.count - header), "Envelope length")
    try require(read.fingerprint == fingerprint, "Envelope fingerprint")
    let body = slice(bytes, header, bytes.count)
    try require(sha256Hex(body) == hex(slice(bytes, 50, 82)), "Envelope hash")
    if let rawKey = rawKey {
      try require(rawKey.count == 32, "Raw Ed25519 public key required")
      // Pure Ed25519 signs the header followed by the ZIP, not a prehash.
      try require(
        Ed25519.verify(key: rawKey, signature: slice(bytes, 82, header), message: slice(bytes, 0, 82) + body),
        "Envelope signature")
    }
    return read
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

typealias Progress = (_ phase: String, _ received: Int64, _ total: Int64) -> Void

/// Bytecode candidates of a patchable host: every rule a patch file is held
/// to, the same as Android's PatchHost. A file is accepted when it is this
/// host's ([BytecodeEnvelope.verify]) and numbered above every file accepted
/// before; a withdrawal is a file with no payload, after which no patch is
/// active. All state changes hold [lock].
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
  private let bundle: Bundle
  private var claimed = false
  private var offered: String?
  private var attempt: BytecodeAttempt?
  private var offeredMeta: CandidateStore.Meta?
  private var storeValue: CandidateStore?
  private var hostValue: HostTrustConfig??

  /// [host] stands in for the policy in [bundle]'s Info.plist.
  init(host: HostTrustConfig? = nil, bundle: Bundle = .main) {
    self.bundle = bundle
    if let host = host { hostValue = .some(host) }
  }

  /// Lets a test start what the next process would see.
  static func debugNewProcess() { lock.lock(); processClaimed = false; lock.unlock() }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return try body()
  }

  private func store() throws -> CandidateStore {
    if let store = storeValue { return store }
    // 1.0 kept signed-manifest state here; nothing reads it any more.
    let legacy = try Storage.root().appendingPathComponent("auth", isDirectory: true)
    if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
    let store = try CandidateStore(strategy: "bytecode")
    storeValue = store
    return store
  }

  /// nil on an app without a bytecode host policy.
  private func host() throws -> HostTrustConfig? {
    if let host = hostValue { return host }
    let host = try HostTrustConfig.load(bundle)
    hostValue = .some(host)
    return host
  }

  private func patchable() throws -> HostTrustConfig {
    guard let host = try host() else { throw PatcherError("This app was not built with flutter_patcher") }
    return host
  }

  func announceBootstrap() { locked { bootstrapped = true } }

  func bootPayload(fingerprint fp: String, publicKey: String) throws -> [String: Any]? {
    try locked {
      let started = DispatchTime.now().uptimeNanoseconds
      let host = try bootstrap(fp, publicKey)
      if claimed || Self.processClaimed { return nil }
      Self.processClaimed = true
      claimed = true
      let store = try store()
      try store.recoverAttempt()
      guard let meta = try store.activeFor(fp) else {
        store.noPatch()
        return nil
      }
      do {
        var reply = try offer(store, meta, host)
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
  /// runs as built. Before this process boots, the active candidate. nil runs
  /// the entry point as built.
  func backgroundPayload(fingerprint fp: String, publicKey: String) throws -> [String: Any]? {
    try locked {
      let host = try bootstrap(fp, publicKey)
      let store = try store()
      let claimed = self.claimed || Self.processClaimed
      guard let meta = claimed ? (attempt?.failed == true ? nil : offeredMeta) : try store.activeFor(fp)
      else { return nil }
      do {
        return try offer(store, meta, host).merging(["transportVersion": 1]) { $1 }
      } catch {
        // The candidate is the app isolate's to judge; this engine runs as built.
        NSLog("[FlutterPatcher] Background payload rejected: \(error)")
        return nil
      }
    }
  }

  private func bootstrap(_ fp: String, _ publicKey: String) throws -> HostTrustConfig {
    let host = try patchable()
    let key = host.fptcKey.map { $0.base64EncodedString() } ?? "-"
    try require(fp == host.fingerprint && publicKey == key, "Bootstrap differs from immutable host")
    return host
  }

  /// [meta]'s stored file, verified, as offer fields; this exact snapshot goes to Dart.
  private func offer(_ store: CandidateStore, _ meta: CandidateStore.Meta, _ host: HostTrustConfig) throws
    -> [String: Any]
  {
    let bytes = try Storage.read(store.fileURL(meta), limit: BytecodeEnvelope.maxBytes)
    let seq = try BytecodeEnvelope.verify(bytes, fingerprint: host.fingerprint, rawKey: host.fptcKey).seq
    try require(seq == int64(meta["seq"]) && BytecodeEnvelope.identifies(bytes, meta), "Stored candidate changed")
    // The bootstrap reads the same ranges and skips only the CRCs and
    // digests checked here; see parseAuthenticatedPatchBytes.
    return ["envelopeBytes": bytes, "entries": try PatchArchive.readBytecode(bytes, fingerprint: host.fingerprint, seq: seq)]
  }

  func markBooting(_ token: String?, foreground: Bool = true) throws -> Bool {
    try locked {
      guard let token = token, token == offered, attempt?.running != true, attempt?.failed != true,
            let meta = offeredMeta
      else { return false }
      let store = try store()
      // A rollback, withdrawal or newly installed candidate invalidates a prepared offer.
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

  /// Who this host is, for an app that fetches its own patch files.
  func target() throws -> [String: Any]? {
    try locked {
      guard let host = try host() else { return nil }
      return ["scope": host.scope, "signed": host.fptcKey != nil, "acceptedSeq": try store().high(host.fingerprint)]
    }
  }

  /// Whether a file starting with [header] would be accepted, judged from its
  /// first [BytecodeEnvelope.header] bytes: nothing about its payload or
  /// signature is known yet, so installing it still verifies everything.
  func inspect(_ header: Data) throws -> [String: Any] {
    try locked {
      let host = try patchable()
      let read: BytecodeEnvelope.Header
      do { read = try BytecodeEnvelope.readHeader(header) } catch {
        return ["fresh": false, "action": NSNull(), "seq": NSNull(), "reason": "\(error)"]
      }
      var reason: String?
      if read.fingerprint != host.fingerprint {
        reason = "Patch file of another host"
      } else if read.seq <= (try store().high(host.fingerprint)) {
        reason = "Not newer than the accepted patch"
      }
      return [
        "fresh": reason == nil, "action": read.withdrawal ? "withdraw" : "publish", "seq": read.seq,
        "reason": reason ?? NSNull(),
      ]
    }
  }

  /// Installs or applies the patch file at [path]; the caller owns the file.
  func applyFile(_ path: String, progress: Progress) throws -> [String: Any] {
    let bytes: Data
    do { bytes = try Storage.read(URL(fileURLWithPath: path), limit: BytecodeEnvelope.maxBytes) } catch {
      return Self.failure("IO_ERROR", "\(error)")
    }
    return try apply(bytes, progress: progress)
  }

  /// Installs the patch file [bytes], or applies the withdrawal they are.
  func apply(_ bytes: Data, progress: Progress) throws -> [String: Any] {
    try locked {
      let host = try patchable()
      try HostTrustConfig.requireOwner(bundle)
      let total = Int64(bytes.count)
      progress("verifying", total, total)
      let header: BytecodeEnvelope.Header
      do { header = try BytecodeEnvelope.verify(bytes, fingerprint: host.fingerprint, rawKey: host.fptcKey) } catch {
        return Self.failure("SIGNATURE_INVALID", "\(error)")
      }
      var result = try header.withdrawal ? withdraw(host, header.seq) : install(host, bytes, header.seq, progress)
      result["action"] = header.withdrawal ? "withdraw" : "publish"
      return result
    }
  }

  private static func failure(_ code: String, _ message: String) -> [String: Any] {
    ["ok": false, "error": code, "message": message]
  }

  private static let success: [String: Any] = ["ok": true, "error": NSNull(), "message": NSNull()]

  private func withdraw(_ host: HostTrustConfig, _ seq: Int64) throws -> [String: Any] {
    let store = try store()
    if seq <= store.high(host.fingerprint) {
      return Self.failure("INVALID_ARGS", "Withdrawal is not newer than the accepted patch")
    }
    try store.withdraw(host.fingerprint, seq)
    dropOffer()
    return Self.success
  }

  private func install(_ host: HostTrustConfig, _ bytes: Data, _ seq: Int64, _ progress: Progress) throws
    -> [String: Any]
  {
    let store = try store()
    var meta = store.candidate(fingerprint: host.fingerprint, seq: seq, sha256: sha256Hex(bytes))
    meta["header_sha256"] = BytecodeEnvelope.headerDigest(bytes)
    if store.isBlacklisted(meta) { return Self.failure("BLACKLISTED", "Bytecode candidate is blacklisted") }
    if !store.isNewer(meta) { return Self.failure("INVALID_ARGS", "Patch is not newer than the accepted patch") }
    let total = Int64(bytes.count)
    progress("finalizing", total, total)
    do { try store.save(meta, bytes: bytes) } catch { return Self.failure("IO_ERROR", "\(error)") }
    return Self.success
  }

  func rollback() throws {
    try locked {
      if try host() != nil { try HostTrustConfig.requireOwner(bundle) }
      try store().clearActive()
      dropOffer()
    }
  }

  /// No offer of this process stands after its patch is gone.
  private func dropOffer() {
    offered = nil
    attempt = nil
    frameToken = nil
  }

  func currentVersion() throws -> String? { try locked { try store().active()?["version"] as? String } }

  func blacklist() throws -> [[String: Any]] { try locked { try store().blacklist() } }

  func clearBlacklist() throws {
    try locked {
      if try host() != nil { try HostTrustConfig.requireOwner(bundle) }
      try store().clearBlacklist()
    }
  }
}
