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

/// The host policy `build ios` put in the app's Info.plist; never a mutable
/// Dart config or a patched asset: which build this is and the patch key it
/// trusts, if any ([fptcKey] nil: patch files are not signed).
final class HostTrustConfig {
  static let infoKey = "FlutterPatcherHostTrust"
  static let scopeKeys: Set<String> = [
    "application_id", "channel", "flavor", "version_code", "abi", "fingerprint", "strategy",
  ]
  private static let policyKeys = scopeKeys.subtracting(["fingerprint"]).union(["schema", "fptc_key"])

  let scope: [String: String]
  let fptcKey: Data?
  /// Where `build` was told devices download patches; outside the policy and its hash.
  let url: String?
  var strategy: String { scope["strategy"]! }
  var fingerprint: String { scope["fingerprint"]! }

  init(scope: [String: String], fptcKey: Data?, url: String?) {
    self.scope = scope
    self.fptcKey = fptcKey
    self.url = url
  }

  static func load(_ bundle: Bundle = .main) throws -> HostTrustConfig? {
    guard let text = bundle.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
    let host = try parse(text)
    try require(
      host.scope["application_id"] == bundle.bundleIdentifier
        && host.scope["version_code"] == String(Platform.versionCode(bundle)) && host.scope["abi"] == Platform.abi,
      "Host policy target")
    return host
  }

  static func canonical(_ fields: [String: String]) -> String {
    "{" + fields.keys.sorted().map { "\"\($0)\":\"\(fields[$0]!)\"" }.joined(separator: ",") + "}"
  }

  /// The packed host trust [wrapperText]: policy schema 2, its digest, fingerprint and optional url.
  static func parse(_ wrapperText: String) throws -> HostTrustConfig {
    try require(!wrapperText.isEmpty && wrapperText.utf8.count <= 24000, "Host policy size")
    let wrapper = try JSONText.object(wrapperText)
    guard let text = wrapper["policy"] as? String, let fingerprint = wrapper["fingerprint"] as? String,
          let declared = wrapper["policy_sha256"] as? String
    else { throw PatcherError("Host policy wrapper") }
    let policy = try JSONText.strings(text)
    try require(text == canonical(policy), "Host policy canonical form")
    try require(Set(policy.keys) == policyKeys && policy["schema"] == "2", "Host policy fields")
    try require(sha256Hex(Data(text.utf8)) == declared, "Host policy hash")
    var scope = [String: String]()
    for key in scopeKeys { scope[key] = key == "fingerprint" ? fingerprint : policy[key]! }
    func matches(_ key: String, _ pattern: String) -> Bool { fullMatch(pattern, scope[key]!) }
    try require(matches("fingerprint", "[0-9a-f]{64}"), "Fingerprint")
    try require(matches("application_id", "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+"), "Application")
    try require(matches("channel", "[A-Za-z0-9_]{1,64}") && matches("flavor", "[A-Za-z0-9_]{1,64}"),
      "Channel/flavor")
    try require(matches("version_code", "[1-9][0-9]{0,9}") && Int64(scope["version_code"]!)! <= 2_100_000_000,
      "Version code")
    try require(scope["abi"] == Platform.abi && scope["strategy"] == "bytecode", "ABI/strategy")
    var key: Data?
    if policy["fptc_key"] != "-" {
      key = try strictBase64(policy["fptc_key"]!)
      try require(key!.count == 32, "Host key encoding")
    }
    let url = wrapper["url"] as? String
    try require(wrapper["url"] == nil || url.map { $0.hasPrefix("https://") || $0.hasPrefix("http://") } == true,
      "Host URL")
    return HostTrustConfig(scope: scope, fptcKey: key, url: url)
  }

  /// Patches are managed by the app itself, never by an extension sharing the plugin.
  static func requireOwner(_ bundle: Bundle = .main) throws {
    try require(bundle.bundleURL.pathExtension == "app", "Patches are managed by the main app")
  }
}
