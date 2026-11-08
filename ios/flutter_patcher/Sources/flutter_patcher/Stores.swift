import Foundation

/// Runtime configuration from Dart `init()`. Trust material never passes here.
enum PatcherConfig {
  static let defaultMaxCrash = 1

  private static func file() throws -> JSONFile { JSONFile(try Storage.root().appendingPathComponent("config.json")) }

  static func save(maxCrashCount: Int) throws { try file().write(["max_crash_count": max(1, maxCrashCount)]) }

  static func maxCrashCount() -> Int {
    (try? file().read()["max_crash_count"] as? Int) ?? defaultMaxCrash
  }
}

/// iOS has no ApplicationExitInfo, so this is Android's rule below API 30: a
/// process that ended before its first frame (still `loading`) crashed. A
/// crash after the first frame is not detected; Dart errors are reported apart.
/// Unlike that rule, `loading` is held only while the app is in the
/// foreground: the system ending a backgrounded (or background-launched)
/// app, or the user swiping it away, is not a crash (Android API 30+ tells
/// these apart through ApplicationExitInfo).
enum CrashGuard {
  static func previousSessionCrashed(loading: Bool) -> Bool { loading }
}

/// The last cold start's patch decision; statuses match the Android plugin.
enum BootDiagnosticStore {
  static let noPatch = "NO_PATCH"
  static let patched = "PATCHED"
  static let droppedVersionCodeMismatch = "DROPPED_VERSION_CODE_MISMATCH"
  static let droppedCircuitBreaker = "DROPPED_CIRCUIT_BREAKER"
  static let bytecodeBootFailed = "BYTECODE_BOOT_FAILED"
  static let unknown = "UNKNOWN"

  private static func file() throws -> JSONFile {
    JSONFile(try Storage.root().appendingPathComponent("last_boot_diagnostic.json"))
  }

  static func record(
    _ status: String, patchVersion: String? = nil, patchTargetVersionCode: Int64? = nil, crashCount: Int? = nil,
    message: String? = nil
  ) {
    var value: [String: Any] = [
      "status": status, "appVersionCode": Platform.versionCode(),
      "recordedAt": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    if let patchVersion = patchVersion { value["patchVersion"] = patchVersion }
    if let patchTargetVersionCode = patchTargetVersionCode { value["patchTargetVersionCode"] = patchTargetVersionCode }
    if let crashCount = crashCount { value["crashCount"] = crashCount }
    if let message = message { value["message"] = message }
    try? file().write(value)
  }

  /// A previous DROPPED_* or *_BOOT_FAILED explains why no patch runs; keep it.
  static func recordNoPatch() {
    if let previous = read()?["status"] as? String,
       previous.hasPrefix("DROPPED_") || previous.hasSuffix("_BOOT_FAILED") { return }
    record(noPatch)
  }

  /// The channel map; nil when nothing was recorded yet.
  static func read() -> [String: Any]? {
    guard let stored = try? file().read(), !stored.isEmpty else { return nil }
    var result = [String: Any]()
    for key in [
      "status", "patchVersion", "patchTargetVersionCode", "appVersionCode", "crashCount",
      "attemptedLoaderFields", "message",
    ] { result[key] = stored[key] ?? NSNull() }
    result["recordedAt"] = stored["recordedAt"] ?? 0
    if !(result["status"] is String) { result["status"] = unknown }
    return result
  }
}

/// Durable state of FPTC candidates: content-addressed files, the
/// active candidate, the boot attempt, crash counts, blacklist and sequence
/// high-water marks. Only the active candidate keeps its file, as on
/// Android. Callers serialize access.
final class CandidateStore {
  typealias Meta = [String: Any]

  private let strategy: String
  private let directory: URL
  private let file: JSONFile
  private var state: [String: Any]

  init(strategy: String) throws {
    self.strategy = strategy
    let root = try Storage.root()
    directory = root.appendingPathComponent(strategy, isDirectory: true)
    file = JSONFile(root.appendingPathComponent("\(strategy).json"))
    state = file.read()
  }

  func active() -> Meta? { state["active"] as? Meta }

  func id(_ meta: Meta) -> String {
    "\(meta["fingerprint"] as? String ?? ""):\(int64(meta["seq"]) ?? 0):\(meta["sha256"] as? String ?? "")"
  }

  func fileURL(_ meta: Meta) -> URL { directory.appendingPathComponent("\(meta["sha256"] as? String ?? "-").fptc") }

  /// Settles the attempt left by the previous process; a crash counts as a failure.
  func recoverAttempt() throws {
    guard let prior = state["attempt_meta"] as? Meta else { return }
    if CrashGuard.previousSessionCrashed(loading: state["loading"] as? Bool ?? false) {
      try recordFailure(prior, "Previous process crashed")
    }
    try clearAttempt()
  }

  /// The active, non-blacklisted candidate of this host build; a stale one is dropped.
  func activeFor(_ fingerprint: String) throws -> Meta? {
    guard let meta = active() else { return nil }
    if meta["fingerprint"] as? String != fingerprint || int64(meta["versionCode"]) != Platform.versionCode() {
      try commit { $0.removeValue(forKey: "active") }
      diagnostic(BootDiagnosticStore.droppedVersionCodeMismatch, "Host identity changed", meta)
      return nil
    }
    return isBlacklisted(meta) ? nil : meta
  }

  func candidate(fingerprint: String, seq: Int64, sha256: String) -> Meta {
    ["fingerprint": fingerprint, "seq": seq, "sha256": sha256, "version": String(seq), "versionCode": Platform.versionCode()]
  }

  func isBlacklisted(_ meta: Meta) -> Bool { state["bad:\(id(meta))"] as? Bool ?? false }

  /// The largest sequence accepted for [fingerprint], patch or withdrawal; 0 before any.
  func high(_ fingerprint: String) -> Int64 { int64(state["high:\(fingerprint)"]) ?? 0 }

  /// Whether [meta] may become active: the active candidate again, or newer than any accepted.
  func isNewer(_ meta: Meta) -> Bool {
    active().map { id($0) == id(meta) } == true || int64(meta["seq"]) ?? 0 > high(meta["fingerprint"] as? String ?? "")
  }

  func requireNewer(_ meta: Meta) throws {
    try require(isNewer(meta), "Patch sequence must exceed accepted high-water mark")
  }

  /// A withdrawal numbered [seq]: no patch is active, and only later files are accepted.
  func withdraw(_ fingerprint: String, _ seq: Int64) throws {
    try require(seq > high(fingerprint), "Withdrawal sequence must exceed accepted high-water mark")
    try commit {
      Self.clearingAttempt(&$0)
      $0.removeValue(forKey: "active")
      $0["high:\(fingerprint)"] = seq
    }
  }

  /// Makes [meta] active, keeping [bytes] as its envelope file.
  func save(_ meta: Meta, bytes: Data) throws {
    try requireNewer(meta)
    try Storage.durableWrite(bytes, to: fileURL(meta))
    let key = "high:\(meta["fingerprint"] as? String ?? "")"
    try commit {
      $0["active"] = meta
      $0[key] = max(int64(meta["seq"]) ?? 0, int64($0[key]) ?? 0)
    }
  }

  func markLoading(_ meta: Meta, foreground: Bool) throws {
    try commit {
      $0["attempt_meta"] = meta
      $0["loading"] = foreground
      $0["paused"] = !foreground
      $0["pid"] = Int(getpid())
    }
  }

  /// The app left the foreground before the attempt's first frame.
  func pauseLoading() throws {
    guard state["attempt_meta"] != nil, state["loading"] as? Bool == true else { return }
    try commit {
      $0["loading"] = false
      $0["paused"] = true
    }
  }

  /// The app is back in the foreground with the attempt still unconfirmed.
  func resumeLoading() throws {
    guard state["attempt_meta"] != nil, state["paused"] as? Bool == true else { return }
    try commit {
      $0["loading"] = true
      $0["paused"] = false
    }
  }

  func markSuccess(_ meta: Meta) throws {
    let key = "crashes:\(id(meta))"
    try commit {
      $0["loading"] = false
      $0["paused"] = false
      $0[key] = 0
    }
  }

  func clearAttempt() throws { try commit(Self.clearingAttempt) }

  /// Keeps high-water marks and the blacklist.
  func clearActive() throws {
    try commit {
      Self.clearingAttempt(&$0)
      $0.removeValue(forKey: "active")
    }
  }

  func recordFailure(_ meta: Meta, _ message: String, quarantine: Bool = false, increment: Bool = true) throws {
    let key = id(meta)
    let count = (state["crashes:\(key)"] as? Int ?? 0) + (increment ? 1 : 0)
    let tripped = quarantine || count >= PatcherConfig.maxCrashCount()
    let ownsAttempt = (state["attempt_meta"] as? Meta).map { id($0) == key } == true
    let ownsActive = active().map { id($0) == key } == true
    // Counting and consuming the old attempt are one durable write.
    try commit {
      $0["crashes:\(key)"] = count
      if ownsAttempt { Self.clearingAttempt(&$0) }
      if tripped {
        $0["bad:\(key)"] = true
        if $0["badAt:\(key)"] == nil { $0["badAt:\(key)"] = Int64(Date().timeIntervalSince1970 * 1000) }
        if ownsActive { $0.removeValue(forKey: "active") }
      }
    }
    diagnostic(
      tripped ? BootDiagnosticStore.droppedCircuitBreaker : BootDiagnosticStore.bytecodeBootFailed, message, meta,
      count)
  }

  func diagnostic(_ status: String, _ message: String, _ meta: Meta? = nil, _ count: Int = 0) {
    BootDiagnosticStore.record(
      status, patchVersion: meta?["version"] as? String,
      patchTargetVersionCode: meta.flatMap { int64($0["versionCode"]) }, crashCount: count, message: message)
  }

  func noPatch() { BootDiagnosticStore.recordNoPatch() }

  func blacklist() -> [[String: Any]] {
    state.filter { $0.key.hasPrefix("bad:") && $0.value as? Bool == true }.map { entry -> [String: Any] in
      let id = String(entry.key.dropFirst(4))
      return [
        "version": id, "reason": "BOOT_CRASH", "strategy": strategy,
        "blacklistedAt": int64(state["badAt:\(id)"]) ?? 0,
      ]
    }
  }

  func clearBlacklist() throws {
    try commit { state in
      for key in state.keys where key.hasPrefix("bad:") || key.hasPrefix("badAt:") || key.hasPrefix("crashes:") {
        state.removeValue(forKey: key)
      }
    }
  }

  private static func clearingAttempt(_ state: inout [String: Any]) {
    state.removeValue(forKey: "attempt_meta")
    state.removeValue(forKey: "pid")
    state.removeValue(forKey: "paused")
    state["loading"] = false
  }

  private func commit(_ change: (inout [String: Any]) -> Void) throws {
    var next = state
    change(&next)
    try file.write(next)
    let replaced = (state["active"] as? Meta).map { id($0) } != (next["active"] as? Meta).map { id($0) }
    state = next
    // One candidate per host: whatever stops being active loses its files.
    // A running patch already holds its bytes.
    if replaced { prune() }
  }

  private func prune() {
    let keep = active().map { fileURL($0).lastPathComponent }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name != keep {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}
