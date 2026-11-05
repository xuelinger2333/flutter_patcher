import CryptoKit
import Foundation

enum Ed25519 {
  static func verify(key: Data, signature: Data, message: Data) -> Bool {
    guard key.count == 32, signature.count == 64,
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
    else { return false }
    return publicKey.isValidSignature(signature, for: message)
  }
}

/// Pure protocol verification, the same rules as the Android PublishManifest.
/// The caller persists decisions; nothing here has side effects.
enum PublishManifest {
  static let domain = Data("flutter_patcher.manifest.v1\n".utf8)
  static let scopeKeys: Set<String> = [
    "application_id", "channel", "flavor", "version_code", "abi", "fingerprint", "strategy",
  ]
  private static let common = scopeKeys.union(["schema", "key_id", "revision", "minPluginVersion", "action"])

  struct State: Equatable {
    var revision: Int64 = 0
    var manifestHash = ""
    var highSeq: Int64 = 0
    var patchHash = ""
    var withdrawnThrough: Int64 = 0
  }

  struct Decision {
    let action: String
    let fields: [String: String]
    let next: State
  }

  static func canonical(_ fields: [String: String]) -> String {
    "{" + fields.keys.sorted().map { "\"\($0)\":\"\(fields[$0]!)\"" }.joined(separator: ",") + "}"
  }

  static func parse(_ bytes: Data) throws -> [String: String] {
    try require(bytes.count <= 16384, "Manifest too large")
    guard let text = String(data: bytes, encoding: .utf8) else { throw PatcherError("Manifest UTF-8") }
    let f = try JSONText.strings(text)
    let publish = f["action"] == "publish"
    try require(
      Set(f.keys) == common.union(publish ? ["patch_seq", "sha256", "size", "path"] : ["withdraw_through_seq"]),
      "Unexpected fields")
    try require(f["schema"] == "1" && (publish || f["action"] == "withdraw"), "Schema/action")
    try require(
      f.values.allSatisfy { value in
        value.utf8.count <= 2048
          && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 && $0 != "\"" && $0 != "\\" }
      }, "ASCII values")
    func matches(_ key: String, _ pattern: String) -> Bool { fullMatch(pattern, f[key]!) }
    for key in ["key_id", "channel", "flavor"] {
      try require(matches(key, "[A-Za-z0-9_-]{1,64}"), key)
    }
    try require(matches("application_id", "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+"), "Application")
    // Protocol rules shared with the CLI and Android; the host scope pins the
    // ABI, and iOS hosts load bytecode only.
    let platform = ["arm64-v8a": "android", "ios-arm64": "ios"][f["abi"]!]
    try require(
      platform != nil && ["bytecode", "so"].contains(f["strategy"]!)
        && (platform != "ios" || f["strategy"] == "bytecode"), "ABI/strategy")
    try require(
      matches("fingerprint", "[0-9a-f]{64}") || (f["strategy"] == "so" && f["fingerprint"] == "-"), "Fingerprint")
    _ = try version(f["minPluginVersion"]!)
    func number(_ key: String, _ max: Int64) throws {
      try require(matches(key, "[1-9][0-9]{0,15}") && Int64(f[key]!)! <= max, key)
    }
    try number("version_code", 2_100_000_000)
    try number("revision", 9_007_199_254_740_991)
    try number(publish ? "patch_seq" : "withdraw_through_seq", 4_294_967_295)
    if publish {
      try number("size", 320 * 1024 * 1024)
      try require(matches("sha256", "[0-9a-f]{64}"), "SHA256")
      // Relative to the manifest, so the store can move between hosts.
      try require(
        matches("path", "objects/[0-9a-f]{32}/[0-9a-f]{64}\\.fptc")
          && f["path"]!.hasSuffix("/\(f["sha256"]!).fptc"), "Payload path")
    }
    try require(text == canonical(f), "Noncanonical manifest")
    return f
  }

  private static func version(_ value: String) throws -> [Int] {
    try require(
      fullMatch("(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})", value), "Plugin version")
    return value.split(separator: ".").map { Int($0)! }
  }

  private static func compatible(_ actual: String, _ minimum: String) throws -> Bool {
    let a = try version(actual), b = try version(minimum)
    for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
    return true
  }

  /// [envelope] holds Base64 `payload` and `signature`, in canonical form.
  static func envelope(_ wire: String, maxPayload: Int) throws -> (payload: Data, signature: Data) {
    try require(wire.utf8.count <= 24000, "Envelope size")
    let fields = try JSONText.strings(wire)
    try require(Set(fields.keys) == ["payload", "signature"], "Envelope fields")
    guard let payload = Data(base64Encoded: fields["payload"]!),
          let signature = Data(base64Encoded: fields["signature"]!)
    else { throw PatcherError("Envelope encoding") }
    try require(signature.count == 64 && !payload.isEmpty && payload.count <= maxPayload, "Envelope size")
    try require(
      wire == "{\"payload\":\"\(payload.base64EncodedString())\",\"signature\":\"\(signature.base64EncodedString())\"}",
      "Noncanonical envelope")
    return (payload, signature)
  }

  /// [trustedKeys] and [scope] come from the host, never from this envelope.
  static func verify(
    _ wire: String, trustedKeys: [String: Data], scope: [String: String], pluginVersion: String, state: State
  ) throws -> Decision {
    try require(Set(scope.keys) == scopeKeys, "Envelope scope")
    let (bytes, signature) = try envelope(wire, maxPayload: 16384)
    let f = try parse(bytes)
    guard let key = trustedKeys[f["key_id"]!] else { throw PatcherError("Unknown key") }
    try require(Ed25519.verify(key: key, signature: signature, message: domain + bytes), "Manifest signature")
    try require(scope.allSatisfy { f[$0.key] == $0.value }, "Wrong target")
    try require(try compatible(pluginVersion, f["minPluginVersion"]!), "Plugin too old")
    let revision = Int64(f["revision"]!)!
    let digest = sha256Hex(bytes)
    try require(revision >= state.revision, "Stale manifest")
    if revision == state.revision {
      try require(digest == state.manifestHash, "Revision conflict")
      // Idempotent authorization, not a signal to reinstall or skip a failed download.
      return Decision(action: f["action"]!, fields: f, next: state)
    }
    var next = state
    next.revision = revision
    next.manifestHash = digest
    if f["action"] == "withdraw" {
      let floor = max(state.withdrawnThrough, Int64(f["withdraw_through_seq"]!)!)
      next.highSeq = max(state.highSeq, floor)
      next.withdrawnThrough = floor
      return Decision(action: "withdraw", fields: f, next: next)
    }
    let seq = Int64(f["patch_seq"]!)!
    let patchHash = f["sha256"]!
    try require(
      seq > state.withdrawnThrough && (seq > state.highSeq || (seq == state.highSeq && patchHash == state.patchHash)),
      "Patch sequence conflict")
    next.highSeq = seq
    next.patchHash = patchHash
    return Decision(action: "publish", fields: f, next: next)
  }
}

/// A complete root-authorized key set. Publishing keys cannot sign this document.
enum TrustUpdate {
  static let domain = Data("flutter_patcher.trust.v1\n".utf8)

  struct Decision {
    let revision: Int64
    let hash: String
    let keys: [String: Data]
  }

  static func keys(_ value: String) throws -> [String: Data] {
    if value == "-" { return [:] }
    let rows = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    try require((1...32).contains(rows.count) && rows == rows.sorted(), "Key set order/size")
    var result = [String: Data]()
    for row in rows {
      let pair = row.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      try require(pair.count == 2 && fullMatch("[A-Za-z0-9_-]{1,64}", pair[0]), "Key identifier")
      let bytes = try strictBase64(pair[1])
      try require(bytes.count == 32, "Key encoding")
      try require(result.updateValue(bytes, forKey: pair[0]) == nil, "Duplicate key")
    }
    return result
  }

  static func verify(
    _ wire: String, root: Data, scope: [String: String], revision: Int64, previousHash: String
  ) throws -> Decision {
    try require(Set(scope.keys) == PublishManifest.scopeKeys, "Trust scope")
    let (bytes, signature) = try PublishManifest.envelope(wire, maxPayload: 16384)
    // ASCII validation also excludes malformed UTF-8 and JSON escape aliases.
    try require(bytes.allSatisfy { $0 >= 32 && $0 <= 126 }, "Trust ASCII")
    let text = String(decoding: bytes, as: UTF8.self)
    let fields = try JSONText.strings(text)
    try require(Set(fields.keys) == Set(scope.keys).union(["schema", "revision", "keys"]), "Trust fields")
    try require(
      fields.values.allSatisfy { $0.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 && $0 != "\"" && $0 != "\\" } },
      "Trust values")
    try require(text == PublishManifest.canonical(fields) && fields["schema"] == "1", "Trust canonical/schema")
    try require(scope.allSatisfy { fields[$0.key] == $0.value }, "Trust target")
    let value = fields["revision"]!
    try require(fullMatch("[1-9][0-9]{0,15}", value), "Trust revision")
    let next = Int64(value)!
    try require(next <= 9_007_199_254_740_991 && next >= revision, "Stale trust revision")
    let digest = sha256Hex(bytes)
    try require(next != revision || digest == previousHash, "Trust revision conflict")
    let keySet = try keys(fields["keys"]!)
    try require(Ed25519.verify(key: root, signature: signature, message: domain + bytes), "Trust signature")
    return Decision(revision: next, hash: digest, keys: keySet)
  }
}

/// The host policy signed into the app's Info.plist by `build ios`; never a
/// mutable Dart config or a patched asset.
final class HostTrustConfig {
  static let infoKey = "FlutterPatcherHostTrust"

  let scope: [String: String]
  let fptcKey: Data
  let root: Data
  let initialKeys: [String: Data]
  let policyHash: String
  /// Where `build` was told devices download patches; outside the policy and its hash.
  let url: String?
  var strategy: String { scope["strategy"]! }

  private init(
    scope: [String: String], fptcKey: Data, root: Data, initialKeys: [String: Data], policyHash: String,
    url: String?
  ) {
    self.scope = scope
    self.fptcKey = fptcKey
    self.root = root
    self.initialKeys = initialKeys
    self.policyHash = policyHash
    self.url = url
  }

  static func load(_ bundle: Bundle = .main) throws -> HostTrustConfig? {
    guard let wrapperText = bundle.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
    try require(!wrapperText.isEmpty && wrapperText.utf8.count <= 24000, "Host policy size")
    let wrapper = try JSONText.object(wrapperText)
    guard let text = wrapper["policy"] as? String, let fingerprint = wrapper["fingerprint"] as? String,
          let declared = wrapper["policy_sha256"] as? String
    else { throw PatcherError("Host policy wrapper") }
    let policy = try JSONText.strings(text)
    try require(text == PublishManifest.canonical(policy), "Host policy canonical form")
    let expected = PublishManifest.scopeKeys.subtracting(["fingerprint"])
      .union(["schema", "fptc_key", "root_key", "keys"])
    try require(Set(policy.keys) == expected && policy["schema"] == "1" && policy["strategy"] == "bytecode",
      "Host policy fields")
    let hash = sha256Hex(Data(text.utf8))
    try require(hash == declared, "Host policy hash")
    var scope = [String: String]()
    for key in PublishManifest.scopeKeys { scope[key] = key == "fingerprint" ? fingerprint : policy[key]! }
    var probe = scope
    for (key, value) in [
      "schema": "1", "key_id": "root", "revision": "1", "minPluginVersion": "0.0.0",
      "action": "withdraw", "withdraw_through_seq": "1",
    ] { probe[key] = value }
    _ = try PublishManifest.parse(Data(PublishManifest.canonical(probe).utf8))
    try require(
      scope["application_id"] == bundle.bundleIdentifier
        && scope["version_code"] == String(Platform.versionCode(bundle)) && scope["abi"] == Platform.abi,
      "Host policy target")
    func key(_ name: String) throws -> Data {
      let bytes = try strictBase64(policy[name]!)
      try require(bytes.count == 32, "Host key encoding")
      return bytes
    }
    let url = wrapper["url"] as? String
    try require(wrapper["url"] == nil || url.map { $0.hasPrefix("https://") || $0.hasPrefix("http://") } == true,
      "Host URL")
    return HostTrustConfig(
      scope: scope, fptcKey: try key("fptc_key"), root: try key("root_key"),
      initialKeys: try TrustUpdate.keys(policy["keys"]!), policyHash: hash, url: url)
  }

  /// Updates run in the app itself, never in an extension sharing the plugin.
  static func requireOwner(_ bundle: Bundle = .main) throws {
    try require(bundle.bundleURL.pathExtension == "app", "Authenticated updates require the main app")
  }
}
