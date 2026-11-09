import CryptoKit
import Foundation
import zlib

// The device rules of plan/1.1-direct-patching.md §4.3 and the shared FPTC
// vectors, run on macOS against the iOS plugin sources (test/ios/run.sh).

var failures = 0
var passed = 0
func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
  if !condition {
    failures += 1
    print("  FAIL line \(line): \(message())")
  }
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fp-ios-\(UUID().uuidString)")
let app = scratch.appendingPathComponent("Host.app", isDirectory: true)
try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
let appBundle = Bundle(url: app)!

func test(_ name: String, _ body: () throws -> Void) {
  Storage.debugRoot = scratch.appendingPathComponent("store-\(UUID().uuidString)")
  BytecodePatchManager.debugNewProcess()
  let before = failures
  do { try body() } catch {
    failures += 1
    print("  FAIL thrown: \(error)")
  }
  if failures == before { passed += 1; print("ok   \(name)") } else { print("FAIL \(name)") }
}

// MARK: patch files, assembled from the FPTC v1 format

let fp = String(repeating: "ab", count: 32)

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xff) } }
func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(v >> (8 * UInt64($0)) & 0xff) } }

/// A STORED ZIP of [entries], in order.
func zip(_ entries: [(String, Data)]) -> Data {
  var local = [UInt8](), central = [UInt8]()
  for (name, data) in entries {
    let crc = data.withUnsafeBytes { Int(crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt(data.count))) }
    let n = Array(name.utf8)
    let offset = local.count
    local += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(data.count)
      + le32(data.count) + le16(n.count) + le16(0) + n + Array(data)
    central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
      + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
      + le32(offset) + n
  }
  let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(central.count)
    + le32(local.count) + le16(0)
  return Data(local + central + end)
}

func archive(_ seq: Int64) -> Data {
  let code = Data((0..<64).map { UInt8(($0 + Int(seq)) & 0xff) })
  let manifest: [String: Any] = [
    "format_version": 2, "patch_seq": seq, "fingerprint": fp,
    "code": ["kind": "bytecode", "path": "module.bc", "length": code.count, "sha256": sha256Hex(code)],
    "assets": [], "fonts": [],
  ]
  let json = try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
  return zip([("patch_manifest.json", json), ("module.bc", code)])
}

func file(_ payload: Data, _ seq: Int64, key: Curve25519.Signing.PrivateKey? = nil, fingerprint: String = fp) -> Data {
  var header = be(0x4650_5443, 4) + be(1, 2)
  header += stride(from: 0, to: 64, by: 2).map {
    UInt8(fingerprint[fingerprint.index(fingerprint.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
  }
  header += be(UInt64(seq), 4) + be(UInt64(payload.count), 8) + Array(SHA256.hash(data: payload))
  let signature = key.map { try! $0.signature(for: Data(header) + payload) } ?? Data(count: 64)
  return Data(header) + signature + payload
}

func patch(_ seq: Int64, _ key: Curve25519.Signing.PrivateKey? = nil) -> Data { file(archive(seq), seq, key: key) }
func withdrawal(_ seq: Int64, _ key: Curve25519.Signing.PrivateKey? = nil) -> Data { file(Data(), seq, key: key) }

let signer = Curve25519.Signing.PrivateKey()
let scope = [
  "application_id": "com.example.app", "channel": "production", "flavor": "default", "version_code": "7",
  "abi": "ios-arm64", "fingerprint": fp, "strategy": "bytecode",
]
let unsignedHost = HostTrustConfig(scope: scope, fptcKey: nil, policyHash: String(repeating: "0", count: 64), url: nil)
let signedHost = HostTrustConfig(
  scope: scope, fptcKey: signer.publicKey.rawRepresentation, policyHash: String(repeating: "0", count: 64), url: nil)

func process(_ host: HostTrustConfig = unsignedHost) -> BytecodePatchManager {
  BytecodePatchManager.debugNewProcess()
  return BytecodePatchManager(host: host, bundle: appBundle)
}
func key(_ host: HostTrustConfig) -> String { host.fptcKey?.base64EncodedString() ?? "-" }
let noProgress: Progress = { _, _, _ in }
extension BytecodePatchManager {
  func put(_ bytes: Data) throws -> [String: Any] { try apply(bytes, progress: noProgress) }
  func boots(_ host: HostTrustConfig = unsignedHost) throws -> [String: Any]? {
    try bootPayload(fingerprint: fp, publicKey: key(host))
  }
}
func ok(_ result: [String: Any]) -> Bool { result["ok"] as? Bool == true }
func error(_ result: [String: Any]) -> String? { result["error"] as? String }

// MARK: shared vectors

let repo = URL(fileURLWithPath: CommandLine.arguments[1])
let vectors = try! JSONSerialization.jsonObject(
  with: Data(contentsOf: repo.appendingPathComponent("test/protocol/fptc-v1.json"))) as! [String: Any]

test("every vector is accepted or rejected as the format says") {
  for row in vectors["files"] as! [[String: Any]] {
    let name = row["name"] as! String
    let bytes = Data(base64Encoded: row["file"] as! String)!
    let hostKey = (row["host_key"] as? String).map { Data(base64Encoded: $0)! }
    let seq = try? BytecodeEnvelope.verify(bytes, fingerprint: row["fingerprint"] as! String, rawKey: hostKey)
    if row["valid"] as! Bool {
      check(seq == (row["seq"] as! NSNumber).int64Value, name)
      check(try BytecodeEnvelope.readHeader(bytes).withdrawal == (row["action"] as! String == "withdraw"), name)
    } else {
      check(seq == nil, name)
    }
  }
}

// MARK: host policy schema 2

func trust(_ policy: [String: String], fingerprint: String = fp, url: String? = nil) -> String {
  let text = HostTrustConfig.canonical(policy)
  var wrapper: [String: Any] = ["policy": text, "policy_sha256": sha256Hex(Data(text.utf8)), "fingerprint": fingerprint]
  if let url = url { wrapper["url"] = url }
  return String(decoding: try! JSONSerialization.data(withJSONObject: wrapper), as: UTF8.self)
}
let keyText = Data(repeating: 3, count: 32).base64EncodedString()
let fields = [
  "schema": "2", "strategy": "bytecode", "abi": "ios-arm64", "application_id": "com.example.app",
  "version_code": "7", "flavor": "default", "channel": "production", "fptc_key": keyText,
]

test("a signed host trusts its patch key, an unsigned one none") {
  let host = try HostTrustConfig.parse(trust(fields, url: "https://cdn.example.com/p"))
  check(host.fptcKey == Data(repeating: 3, count: 32), "key")
  check(host.fingerprint == fp && host.scope["version_code"] == "7", "scope")
  check(host.url == "https://cdn.example.com/p", "url")
  var unsigned = fields
  unsigned["fptc_key"] = "-"
  check(try HostTrustConfig.parse(trust(unsigned)).fptcKey == nil, "unsigned")
}

test("only schema 2 with exactly its fields is accepted") {
  var bad: [[String: String]] = []
  func with(_ key: String, _ value: String?) -> [String: String] { var f = fields; f[key] = value; return f }
  var schema1 = with("schema", "1")
  schema1["root_key"] = keyText
  schema1["keys"] = "release:\(keyText)"
  bad.append(schema1)
  bad += [
    with("schema", "3"), with("channel", nil), with("extra", "x"), with("fptc_key", "AAAA"),
    with("abi", "arm64-v8a"), with("strategy", "so"), with("version_code", "07"), with("flavor", "a b"), with("flavor", "a-b"), with("channel", "b-c"),
    with("application_id", "example"),
  ]
  for policy in bad { check((try? HostTrustConfig.parse(trust(policy))) == nil, "\(policy)") }
  check((try? HostTrustConfig.parse(trust(fields, fingerprint: String(repeating: "AB", count: 32)))) == nil, "fp")
  check((try? HostTrustConfig.parse(trust(fields, url: "ftp://example.com"))) == nil, "url")
}

// MARK: device rules

test("an unsigned host installs a newer patch for the next cold start") {
  let host = process()
  check(try host.boots() == nil, "no patch yet")
  let result = try host.put(patch(10))
  check(ok(result), "\(result)")
  check(result["action"] as? String == "publish", "action")
  check(try host.currentVersion() == "10", "version")
  check((try host.target()?["acceptedSeq"] as? Int64) == 10, "acceptedSeq")
  check(try process().boots() != nil, "next start boots it")
}

test("a signed host accepts only files signed by its key") {
  let host = process(signedHost)
  check(error(try host.put(patch(10))) == "SIGNATURE_INVALID", "unsigned")
  check(error(try host.put(patch(10, Curve25519.Signing.PrivateKey()))) == "SIGNATURE_INVALID", "other key")
  check(ok(try host.put(patch(10, signer))), "signed")
  check(try process(signedHost).boots(signedHost) != nil, "boots")
}

test("an unsigned host also accepts a signed file") { check(ok(try process().put(patch(10, signer))), "signed") }

test("another host's file is rejected") {
  check(error(try process().put(file(archive(10), 10, fingerprint: String(repeating: "cd", count: 32)))) == "SIGNATURE_INVALID", "fp")
}

test("the active patch again changes nothing") {
  let host = process()
  check(ok(try host.put(patch(10))), "first")
  check(ok(try host.put(patch(10))), "again")
  check(try host.currentVersion() == "10", "version")
}

test("an older or equal sequence is rejected") {
  let host = process()
  check(ok(try host.put(patch(10))), "first")
  check(error(try host.put(patch(9))) == "INVALID_ARGS", "older")
  check(error(try host.put(file(archive(11), 10))) == "INVALID_ARGS", "same seq, other content")
  check(try host.currentVersion() == "10", "version")
}

test("a withdrawal drops the patch and raises the floor") {
  let host = process()
  check(ok(try host.put(patch(10))), "patch")
  let result = try host.put(withdrawal(20))
  check(ok(result) && result["action"] as? String == "withdraw", "\(result)")
  check(try host.currentVersion() == nil, "dropped")
  check((try host.target()?["acceptedSeq"] as? Int64) == 20, "floor")
  check(try process().boots() == nil, "next start runs as built")
  check(error(try host.put(patch(15))) == "INVALID_ARGS", "below floor")
  check(error(try host.put(withdrawal(20))) == "INVALID_ARGS", "same withdrawal")
  check(ok(try host.put(patch(21))), "above floor")
}

test("a signed host needs a signed withdrawal") {
  let host = process(signedHost)
  check(ok(try host.put(patch(10, signer))), "patch")
  check(error(try host.put(withdrawal(20))) == "SIGNATURE_INVALID", "unsigned withdrawal")
  check(try host.currentVersion() == "10", "kept")
  check(ok(try host.put(withdrawal(20, signer))), "signed withdrawal")
  check(try host.currentVersion() == nil, "dropped")
}

test("a local rollback keeps the floor and blacklists nothing") {
  let host = process()
  check(ok(try host.put(patch(10))), "patch")
  try host.rollback()
  check(try host.currentVersion() == nil, "dropped")
  check(try host.blacklist().isEmpty, "no blacklist")
  check(error(try host.put(patch(10))) == "INVALID_ARGS", "same patch")
  check(ok(try host.put(patch(11))), "newer")
}

test("a patch that failed its boot is blacklisted") {
  check(ok(try process().put(patch(10))), "patch")
  let boot = process()
  boot.announceBootstrap()
  let token = try boot.boots()!["attempt"] as! String
  check(try boot.markBooting(token), "started")
  try boot.error(token, message: "boom", quarantine: true)
  check(try process().boots() == nil, "not booted again")
  check(try boot.blacklist().count == 1, "blacklisted")
  check(error(try process().put(patch(10))) == "BLACKLISTED", "refused")
}

test("a withdrawal invalidates an offer that has not started") {
  check(ok(try process().put(patch(10))), "patch")
  let boot = process()
  let token = try boot.boots()!["attempt"] as! String
  _ = try boot.put(withdrawal(20))
  check(try !boot.markBooting(token), "offer invalid")
}

test("inspecting a header tells whether the file is new") {
  let host = process()
  let header = patch(10).prefix(146)
  let fresh = try host.inspect(header)
  check(fresh["fresh"] as? Bool == true && fresh["action"] as? String == "publish" && fresh["seq"] as? Int64 == 10, "\(fresh)")
  check(ok(try host.put(patch(10))), "patch")
  let old = try host.inspect(header)
  check(old["fresh"] as? Bool == false && old["reason"] is String, "\(old)")
  check(try host.inspect(withdrawal(11))["action"] as? String == "withdraw", "withdraw")
  check(try host.inspect(withdrawal(11))["fresh"] as? Bool == true, "withdraw fresh")
  check(try host.inspect(file(Data(), 30, fingerprint: String(repeating: "cd", count: 32)))["fresh"] as? Bool == false, "other host")
  check(try host.inspect(Data(count: 10))["fresh"] as? Bool == false, "short")
}

test("the target names the host and whether it is signed") {
  check(try process().target()?["signed"] as? Bool == false, "unsigned")
  check(try process(signedHost).target()?["signed"] as? Bool == true, "signed")
  check((try process().target()?["acceptedSeq"] as? Int64) == 0, "none accepted")
  check((try process().target()?["scope"] as? [String: String]) == scope, "scope")
}

test("the bootstrap must name the host's key") {
  check(ok(try process().put(patch(10))), "patch")
  check((try? process().bootPayload(fingerprint: fp, publicKey: Data(count: 32).base64EncodedString())) == nil, "wrong key")
  check(try process().bootPayload(fingerprint: fp, publicKey: "-") != nil, "unsigned key")
}

test("signed-manifest state left by 1.0 is removed") {
  let legacy = try Storage.root().appendingPathComponent("auth/\(fp)", isDirectory: true)
  try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
  try Data("{}".utf8).write(to: legacy.appendingPathComponent("state.json"))
  _ = try process().target()
  check(!FileManager.default.fileExists(atPath: try Storage.root().appendingPathComponent("auth").path), "removed")
}

test("a file is read from its path and left there") {
  let path = scratch.appendingPathComponent("patch.fptc")
  try patch(10).write(to: path)
  check(ok(try process().applyFile(path.path, progress: noProgress)), "applied")
  check(FileManager.default.fileExists(atPath: path.path), "kept")
}

try? FileManager.default.removeItem(at: scratch)
print("\(passed) passed, \(failures) failures")
exit(failures == 0 ? 0 : 1)
