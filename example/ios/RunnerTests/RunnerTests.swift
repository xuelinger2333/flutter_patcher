import CryptoKit
import XCTest

@testable import flutter_patcher

/// flutter_patcher's iOS logic, run on a simulator. Loading a bytecode patch
/// needs release AOT on a device and is covered by the device acceptance run.
final class RunnerTests: XCTestCase {
  override func setUpWithError() throws {
    try? FileManager.default.removeItem(at: Storage.root())
  }

  private func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      data.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return data
  }

  /// The FPTC v1 vectors shared with the CLI, Dart and Android tests.
  func testSharedPatchFileVectors() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../../test/protocol/fptc-v1.json").standardized
    let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let rows = vectors["files"] as! [[String: Any]]
    XCTAssertFalse(rows.isEmpty)
    for row in rows {
      let name = row["name"] as! String
      let bytes = Data(base64Encoded: row["file"] as! String)!
      let key = (row["host_key"] as? String).map { Data(base64Encoded: $0)! }
      let seq = try? BytecodeEnvelope.verify(bytes, fingerprint: row["fingerprint"] as! String, rawKey: key)
      if row["valid"] as! Bool {
        XCTAssertEqual(seq, (row["seq"] as! NSNumber).int64Value, name)
      } else {
        XCTAssertNil(seq, name)
      }
    }
  }

  private func envelope(_ fingerprint: Data, seq: UInt32, body: Data, key: Curve25519.Signing.PrivateKey) throws
    -> Data
  {
    var header = Data("FPTC".utf8) + Data([0, 1]) + fingerprint
    header += withUnsafeBytes(of: seq.bigEndian) { Data($0) }
    header += withUnsafeBytes(of: UInt64(body.count).bigEndian) { Data($0) }
    header += Data(SHA256.hash(data: body))
    return header + (try key.signature(for: header + body)) + body
  }

  func testEnvelopeBindsKeyFingerprintAndBytes() throws {
    let key = Curve25519.Signing.PrivateKey()
    let raw = key.publicKey.rawRepresentation
    let fingerprint = Data(repeating: 0xab, count: 32)
    let good = try envelope(fingerprint, seq: 7, body: Data("zip".utf8), key: key)
    XCTAssertEqual(try BytecodeEnvelope.verify(good, fingerprint: hex(fingerprint), rawKey: raw), 7)
    var tampered = good
    tampered[tampered.count - 1] ^= 1
    XCTAssertThrowsError(try BytecodeEnvelope.verify(tampered, fingerprint: hex(fingerprint), rawKey: raw))
    XCTAssertThrowsError(
      try BytecodeEnvelope.verify(good, fingerprint: String(repeating: "cd", count: 32), rawKey: raw))
    XCTAssertThrowsError(
      try BytecodeEnvelope.verify(
        good, fingerprint: hex(fingerprint), rawKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
  }

  func testCrashBeforeFirstFrameTripsTheBreaker() throws {
    try PatcherConfig.save(maxCrashCount: 1)
    let store = try CandidateStore(strategy: "bytecode")
    let meta = store.candidate(fingerprint: "ab", seq: 1, sha256: "cd")
    try store.save(meta, bytes: Data("x".utf8))
    try store.markLoading(meta, foreground: true)
    // The process ends before its first frame; the next launch settles it.
    let next = try CandidateStore(strategy: "bytecode")
    try next.recoverAttempt()
    XCTAssertNil(try next.activeFor("ab"))
    XCTAssertTrue(next.isBlacklisted(meta))
    XCTAssertEqual(BootDiagnosticStore.read()?["status"] as? String, "DROPPED_CIRCUIT_BREAKER")
  }

  func testEndingInTheBackgroundIsNotACrash() throws {
    try PatcherConfig.save(maxCrashCount: 1)
    let store = try CandidateStore(strategy: "bytecode")
    let meta = store.candidate(fingerprint: "ab", seq: 2, sha256: "ce")
    try store.save(meta, bytes: Data("x".utf8))
    // Swiped away (or ended by the system) after leaving the foreground.
    try store.markLoading(meta, foreground: true)
    try store.pauseLoading()
    let next = try CandidateStore(strategy: "bytecode")
    try next.recoverAttempt()
    XCTAssertFalse(next.isBlacklisted(meta))
    // A background launch only arms the breaker once it reaches the foreground.
    try next.markLoading(meta, foreground: false)
    try next.resumeLoading()
    let last = try CandidateStore(strategy: "bytecode")
    try last.recoverAttempt()
    XCTAssertTrue(last.isBlacklisted(meta))
  }

  func testHostPolicyBindsBundleAndBuild() throws {
    let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let policy = HostTrustConfig.canonical([
      "abi": "ios-arm64", "application_id": "com.example.app", "channel": "stable", "flavor": "default",
      "fptc_key": key, "schema": "2", "strategy": "bytecode", "version_code": "3",
    ])
    let trust = String(
      decoding: try JSONSerialization.data(withJSONObject: [
        "policy": policy, "fingerprint": String(repeating: "ab", count: 32),
        "policy_sha256": sha256Hex(Data(policy.utf8)),
      ]), as: UTF8.self)
    func bundle(_ version: String) throws -> Bundle {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.app", "CFBundleVersion": version, HostTrustConfig.infoKey: trust,
      ]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Info.plist"))
      return Bundle(url: url)!
    }
    XCTAssertEqual(try HostTrustConfig.load(bundle("3"))?.scope["fingerprint"], String(repeating: "ab", count: 32))
    XCTAssertThrowsError(try HostTrustConfig.load(bundle("4")))
  }
}
