import CryptoKit
import Foundation

/// A rejected input or state. Messages never carry URLs or credentials.
struct PatcherError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  if !condition { throw PatcherError(message()) }
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

/// Whole-string match; `\A…\z` because `$` also matches before a final newline.
func fullMatch(_ pattern: String, _ value: String) -> Bool {
  guard let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") else { return false }
  return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

/// Standard padded Base64 that re-encodes to exactly [value].
func strictBase64(_ value: String) throws -> Data {
  guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
    throw PatcherError("Base64 encoding")
  }
  return data
}

enum JSONText {
  static func object(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw PatcherError("JSON object required") }
    return value
  }

  /// A flat object of strings. Duplicate keys collapse here; callers reject
  /// them by comparing the text with its canonical form.
  static func strings(_ text: String) throws -> [String: String] {
    var result = [String: String]()
    for (key, value) in try object(text) {
      guard let string = value as? String else { throw PatcherError("String fields required") }
      result[key] = string
    }
    return result
  }
}

enum Platform {
  /// The publish-manifest ABI of every iOS host.
  static let abi = "ios-arm64"

  /// CFBundleVersion, the iOS counterpart of Android's versionCode; -1 if not an integer.
  static func versionCode(_ bundle: Bundle = .main) -> Int64 {
    guard let text = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
          fullMatch("[0-9]{1,18}", text), let value = Int64(text) else { return -1 }
    return value
  }
}

enum Storage {
  /// Replaces Application Support/flutter_patcher in tests.
  static var debugRoot: URL?

  /// Application Support/flutter_patcher, excluded from iCloud and device backups.
  static func root() throws -> URL {
    if let root = debugRoot {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root
    }
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var directory = base.appendingPathComponent("flutter_patcher", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    return directory
  }

  /// Writes a sibling file, fsyncs it, renames it over [url] and fsyncs the
  /// directory, so a killed process leaves either the old or the new bytes.
  static func durableWrite(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(UUID().uuidString + ".pending")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    try require(fd >= 0, "Cannot create \(url.lastPathComponent)")
    var written = 0
    let ok = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
      while written < buffer.count {
        let count = write(fd, buffer.baseAddress! + written, buffer.count - written)
        if count <= 0 { return false }
        written += count
      }
      return fsync(fd) == 0
    }
    close(fd)
    guard ok, rename(temporary.path, url.path) == 0 else {
      unlink(temporary.path)
      throw PatcherError("Cannot commit \(url.lastPathComponent)")
    }
    let directoryFd = open(directory.path, O_RDONLY)
    if directoryFd >= 0 {
      fsync(directoryFd)
      close(directoryFd)
    }
  }

  static func read(_ url: URL, limit: Int) throws -> Data {
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
    try require(size >= 0 && size <= limit, "\(url.lastPathComponent) too large")
    return try Data(contentsOf: url)
  }
}

/// A small JSON dictionary persisted with [Storage.durableWrite]; an absent or
/// unreadable file reads as empty.
final class JSONFile {
  let url: URL
  init(_ url: URL) { self.url = url }

  func read() -> [String: Any] {
    guard let data = try? Storage.read(url, limit: 1 << 20),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return value
  }

  func write(_ value: [String: Any]) throws {
    try Storage.durableWrite(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: url)
  }
}

func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
