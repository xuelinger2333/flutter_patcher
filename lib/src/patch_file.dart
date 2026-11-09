import 'dart:typed_data';

/// The fixed part of an FPTC v1 file before its payload: magic, version,
/// host fingerprint, sequence, payload length, payload SHA-256 and the
/// Ed25519 signature (zero when unsigned).
const patchHeaderSize = 146;

/// The largest patch file a host accepts.
const patchMaxBytes = 320 * 1024 * 1024;

/// The name a host's patch files go by: `patch` writes it, and a host
/// computes it from the scope built into it. The default flavor and channel
/// are left out; otherwise both are named. Flavors and channels have no `-`,
/// so no two hosts share a name.
String patchFileName(Map<String, String> scope) =>
    scope['flavor'] == 'default' && scope['channel'] == 'production'
    ? '${scope['version_code']}-${scope['abi']}.fptc'
    : '${scope['version_code']}-${scope['flavor']}-${scope['channel']}-'
          '${scope['abi']}.fptc';

/// What an FPTC v1 header claims. Nothing here is verified: the host checks
/// the fingerprint, digest and signature before it trusts any of it.
class PatchHeader {
  PatchHeader._(
    this.fingerprint,
    this.seq,
    this.payloadLength,
    this.payloadSha256,
  );

  final String fingerprint;
  final int seq;
  final int payloadLength;
  final String payloadSha256;

  /// A withdrawal carries no payload.
  bool get withdrawal => payloadLength == 0;
  int get fileLength => patchHeaderSize + payloadLength;

  /// Reads the first [patchHeaderSize] bytes of [bytes].
  factory PatchHeader.parse(List<int> bytes) {
    if (bytes.length < patchHeaderSize) {
      throw const FormatException('A patch header has 146 bytes');
    }
    final view = ByteData.sublistView(
      Uint8List.fromList(bytes.sublist(0, patchHeaderSize)),
    );
    if (view.getUint32(0) != 0x46505443 || view.getUint16(4) != 1) {
      throw const FormatException('Not an FPTC v1 patch file');
    }
    String hex(int start, int end) => [
      for (var i = start; i < end; i++)
        view.getUint8(i).toRadixString(16).padLeft(2, '0'),
    ].join();
    return PatchHeader._(
      hex(6, 38),
      view.getUint32(38),
      view.getUint64(42),
      hex(50, 82),
    );
  }
}
