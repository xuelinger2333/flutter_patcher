import Foundation

/// FPTC v1: never allocate from the unauthenticated payload length.
enum BytecodeEnvelope {
  static let maxBytes = 320 * 1024 * 1024

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
  static let pluginVersion = "0.1.4"

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

  /// No ambient credentials, redirects, caches, unbounded bodies or URL diagnostics.
  static func download(_ fields: [String: String]) throws -> Data {
    let expected = Int(fields["size"]!)!
    guard let url = URL(string: fields["url"]!), url.scheme == "https" else { throw PatcherError("HTTPS required") }
    let bytes = try Download(expected: expected).run(url)
    try require(bytes.count == expected && sha256Hex(bytes) == fields["sha256"], "Download digest/size")
    return bytes
  }
}

/// One bounded HTTPS GET on a private ephemeral session.
private final class Download: NSObject, URLSessionDataDelegate {
  private let expected: Int
  private let done = DispatchSemaphore(value: 0)
  private var body = Data()
  private var rejected: String?
  private var failed = false

  init(expected: Int) { self.expected = expected }

  func run(_ url: URL) throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 120
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    session.dataTask(with: url).resume()
    done.wait()
    if let rejected = rejected { throw PatcherError(rejected) }
    if failed { throw PatcherIOError() }
    return body
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil) // A redirect response then fails the status check.
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // Server trust follows the system policy; no other credential is offered.
    completionHandler(
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let http = response as? HTTPURLResponse
    if http?.statusCode != 200 {
      rejected = "Download HTTP status rejected"
    } else if response.expectedContentLength != -1 && response.expectedContentLength != Int64(expected) {
      rejected = "Download length"
    }
    completionHandler(rejected == nil ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if body.count + data.count > expected {
      rejected = "Download size"
      dataTask.cancel()
      return
    }
    body.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if error != nil && rejected == nil { failed = true }
    done.signal()
  }
}

typealias Progress = (_ phase: String, _ received: Int64, _ total: Int64) -> Void

/// Bytecode candidates of an authenticated host. All state changes hold [lock].
final class BytecodePatchManager {
  private static let lock = NSRecursiveLock()
  private static var processClaimed = false

  private(set) var bootstrapped = false
  private(set) var frameToken: String?
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
      guard let auth = try authenticated() else { throw PatcherError("Bytecode requires a host policy") }
      let raw = Data(base64Encoded: publicKey)
      try require(fp == auth.host.scope["fingerprint"] && raw == auth.host.fptcKey,
        "Bootstrap differs from immutable host")
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
        let bytes = try Storage.read(store.fileURL(meta), limit: BytecodeEnvelope.maxBytes)
        let seq = try BytecodeEnvelope.verify(bytes, fingerprint: fp, rawKey: raw!)
        try require(seq == int64(meta["seq"]) && sha256Hex(bytes) == meta["sha256"] as? String,
          "Stored candidate changed")
        let token = UUID().uuidString
        offered = token
        attempt = BytecodeAttempt(token)
        offeredMeta = meta
        // This exact verified snapshot goes to Dart; the file is never reopened.
        return [
          "transportVersion": 1, "envelopeBytes": bytes, "attempt": token,
          "profile_us": ["total": (DispatchTime.now().uptimeNanoseconds - started) / 1000],
        ]
      } catch {
        try store.recordFailure(meta, (error as? PatcherError)?.description ?? "Candidate rejected")
        return nil
      }
    }
  }

  func markBooting(_ token: String?) throws -> Bool {
    try locked {
      guard let token = token, token == offered, attempt?.running != true, attempt?.failed != true,
            let meta = offeredMeta
      else { return false }
      do { try authenticated()?.checkBoot(meta) } catch { return false }
      let store = try store()
      // A rollback or a newly installed candidate invalidates a prepared offer.
      guard store.active().map({ store.id($0) == store.id(meta) }) == true else { return false }
      try store.markLoading(meta)
      let started = attempt?.start(token) == true
      if started { frameToken = token }
      return started
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

  func applyManifest(_ wire: String, progress: Progress) throws -> [String: Any] {
    guard let auth = try locked({ try authenticated() }) else { throw PatcherError("Host has no authenticated policy") }
    let decision = try locked { try auth.verify(wire) }
    if decision.action == "withdraw" {
      try locked {
        _ = try auth.accept(wire)
        try invalidateUnauthorized(auth)
      }
      return ["action": "withdraw", "ok": true]
    }
    progress("downloading", 0, Int64(decision.fields["size"]!)!)
    // Accept only an intact payload, so a failed download stays retryable.
    let bytes = try AuthenticatedUpdates.download(decision.fields)
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
      let meta = store.candidate(
        fingerprint: fingerprint, seq: seq, sha256: hash, version: fields["patch_seq"]!, authorization: wire)
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
