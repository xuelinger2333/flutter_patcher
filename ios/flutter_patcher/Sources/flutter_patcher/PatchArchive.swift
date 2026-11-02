import CryptoKit
import Foundation
import zlib

/// The STORED ZIP payload of a verified bytecode envelope, read as strictly as
/// the Dart bootstrap reads it (`readPatchArchive` in
/// lib/src/bootstrap/patch_archive.dart), so both select the same entry
/// ranges. Checks each entry's CRC and the digest the manifest lists for it;
/// the bootstrap then skips only those two checks, for exactly these ranges.
enum PatchArchive {
  static let format = 2
  private static let maxEntries = 4096
  private static let maxEntry = 64 * 1024 * 1024

  /// Archive path to the envelope offset and length of every entry.
  static func readBytecode(_ envelope: Data, fingerprint: String, seq: Int64) throws -> [String: [Int]] {
    try envelope.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let start = BytecodeEnvelope.header
      let files = try stored(raw, start)
      func bytes(_ range: Range<Int>) -> UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: raw[range]) }
      guard let manifest = files["patch_manifest.json"],
            let m = try? JSONSerialization.jsonObject(with: Data(bytes(manifest))) as? [String: Any]
      else { throw PatcherError("Archive manifest") }
      try require(
        int64(m["format_version"]) == Int64(format) && int64(m["patch_seq"]) == seq
          && m["fingerprint"] as? String == fingerprint, "Manifest identity")
      var listed: Set<String> = ["patch_manifest.json"]
      func check(_ value: Any?, _ prefix: String) throws {
        let row = value as? [String: Any]
        let path = row?["path"] as? String ?? ""
        let range = files[path]
        try require(
          path.hasPrefix(prefix) && listed.insert(path).inserted && range != nil
            && int64(row?["length"]) == Int64(range!.count)
            && row?["sha256"] as? String == hex(Data(SHA256.hash(data: bytes(range!)))), "Entry digest")
      }
      let code = m["code"] as? [String: Any]
      try require(code?["kind"] as? String == "bytecode" && code?["path"] as? String == "module.bc", "Code kind")
      try check(code, "module.bc")
      guard let assets = m["assets"] as? [Any], let fonts = m["fonts"] as? [Any] else {
        throw PatcherError("Resource lists")
      }
      try assets.forEach { try check($0, "assets/") }
      try fonts.forEach { try check($0, "fonts/") }
      try require(listed == Set(files.keys), "Unlisted archive entries")
      return files.mapValues { [$0.lowerBound, $0.count] }
    }
  }

  /// Envelope ranges of the entries of the STORED ZIP in [raw] from [start].
  private static func stored(_ raw: UnsafeRawBufferPointer, _ start: Int) throws -> [String: Range<Int>] {
    let size = raw.count - start
    func range(_ p: Int, _ n: Int) throws { try require(p >= 0 && n >= 0 && p + n <= size, "ZIP bounds") }
    func u16(_ p: Int) throws -> Int {
      try range(p, 2)
      return Int(raw[start + p]) | Int(raw[start + p + 1]) << 8
    }
    func u32(_ p: Int) throws -> Int {
      try range(p, 4)
      return (0..<4).reduce(0) { $0 | Int(raw[start + p + $1]) << (8 * $1) }
    }
    func name(_ p: Int, _ n: Int) throws -> String {
      try range(p, n)
      guard let s = String(bytes: UnsafeRawBufferPointer(rebasing: raw[start + p..<start + p + n]), encoding: .utf8),
            safePath(s)
      else { throw PatcherError("ZIP path") }
      return s
    }

    let end = size - 22
    try require(
      try u32(end) == 0x0605_4b50 && u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 20) == 0,
      "ZIP end record")
    let count = try u16(end + 10), central = try u32(end + 16)
    try require(
      count > 0 && count <= maxEntries && u16(end + 8) == count && central + u32(end + 12) == end,
      "ZIP directory")
    var files: [String: Range<Int>] = [:]
    var cp = central, lp = 0
    for _ in 0..<count {
      try require(try u32(cp) == 0x0201_4b50 && u32(lp) == 0x0403_4b50, "ZIP record")
      let flags = try u16(cp + 8), n = try u16(cp + 28), length = try u32(cp + 24)
      try require(
        try flags & ~0x800 == 0 && u16(cp + 10) == 0 && length == u32(cp + 20) && length <= maxEntry
          && u16(cp + 30) == 0 && u16(cp + 32) == 0 && u16(cp + 34) == 0 && u32(cp + 42) == lp,
        "ZIP unsupported entry")
      let file = try name(cp + 46, n)
      let attributes = try u32(cp + 38), mode = (attributes >> 16) & 0xf000
      try require(mode == 0 || mode == 0x8000, "ZIP non-regular entry")
      try require(attributes & 0x10 == 0 && files[file] == nil, "ZIP duplicate/directory")
      try require(
        try u16(lp + 6) == flags && u16(lp + 8) == 0 && u32(lp + 14) == u32(cp + 16) && u32(lp + 18) == length
          && u32(lp + 22) == length && u16(lp + 26) == n && u16(lp + 28) == 0 && name(lp + 30, n) == file,
        "ZIP local/central mismatch")
      let data = lp + 30 + n
      try range(data, length)
      try require(data + length <= central, "ZIP overlapping entry")
      let base = raw.baseAddress!.assumingMemoryBound(to: Bytef.self) + start + data
      try require(Int(crc32(0, base, uInt(length))) == u32(cp + 16), "ZIP CRC mismatch")
      files[file] = start + data..<start + data + length
      lp = data + length
      cp += 46 + n
    }
    try require(lp == central && cp == end, "ZIP unlisted bytes")
    return files
  }

  private static func safePath(_ path: String) -> Bool {
    !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\u{0}")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}