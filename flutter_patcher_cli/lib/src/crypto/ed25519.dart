import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Ed25519 (RFC 8032 §5.1) in plain Dart, mirroring the verification-only
/// Kotlin implementation shipped in the Android plugin.
///
/// Arithmetic is BigInt based and variable-time. The CLI runs on the
/// developer's build machine with the seed already in memory, not behind a
/// remote timing oracle; the runtime side only ever verifies. Do not lift this
/// into anything that signs on behalf of untrusted callers.

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _order = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d =
    (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final BigInt _sqrtMinusOne =
    BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);
final BigInt _sqrtExponent = (_p + BigInt.from(3)) ~/ BigInt.from(8);

class _Point {
  final BigInt x, y, z, t;
  const _Point(this.x, this.y, this.z, this.t);
}

final _Point _identity =
    _Point(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
final _Point _base =
    _decodePoint(Uint8List.fromList(List<int>.filled(32, 0x66)..[0] = 0x58))!;

_Point _add(_Point p, _Point q) {
  final a = ((p.y - p.x) * (q.y - q.x)) % _p;
  final b = ((p.y + p.x) * (q.y + q.x)) % _p;
  final c = (p.t * BigInt.two * _d * q.t) % _p;
  final d = (p.z * BigInt.two * q.z) % _p;
  final e = b - a, f = d - c, g = d + c, h = b + a;
  return _Point((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _multiply(BigInt scalar, _Point point) {
  var result = _identity, addend = point, k = scalar;
  while (k > BigInt.zero) {
    if (k.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    k >>= 1;
  }
  return result;
}

BigInt _littleEndian(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

Uint8List _toLittleEndian(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = 0; i < length; i++) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

Uint8List _encodePoint(_Point point) {
  final inverse = point.z.modInverse(_p);
  final x = (point.x * inverse) % _p, y = (point.y * inverse) % _p;
  final out = _toLittleEndian(y, 32);
  if (x.isOdd) out[31] |= 0x80;
  return out;
}

/// Returns null for non-canonical or off-curve encodings.
_Point? _decodePoint(Uint8List bytes) {
  if (bytes.length != 32) return null;
  final sign = bytes[31] >> 7;
  final y = _littleEndian(bytes) & ((BigInt.one << 255) - BigInt.one);
  if (y >= _p) return null;
  final y2 = (y * y) % _p;
  final u = (y2 - BigInt.one) % _p, v = (_d * y2 + BigInt.one) % _p;
  final x2 = (u * v.modInverse(_p)) % _p;
  var x = x2.modPow(_sqrtExponent, _p);
  if ((x * x) % _p != x2) x = (x * _sqrtMinusOne) % _p;
  if ((x * x) % _p != x2) return null;
  if (x == BigInt.zero && sign == 1) return null;
  if (x.isOdd != (sign == 1)) x = _p - x;
  return _Point(x, y, BigInt.one, (x * y) % _p);
}

bool _samePoint(_Point a, _Point b) {
  final ai = a.z.modInverse(_p), bi = b.z.modInverse(_p);
  return (a.x * ai) % _p == (b.x * bi) % _p &&
      (a.y * ai) % _p == (b.y * bi) % _p;
}

Uint8List _sha512(List<int> data) =>
    Uint8List.fromList(sha512.convert(data).bytes);

BigInt _clampedScalar(Uint8List hash) {
  final a = Uint8List.fromList(hash.sublist(0, 32));
  a[0] &= 248;
  a[31] &= 127;
  a[31] |= 64;
  return _littleEndian(a);
}

/// 32 random seed bytes from the platform CSPRNG.
Uint8List ed25519GenerateSeed() {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// Raw 32-byte public key for a 32-byte seed.
Uint8List ed25519PublicKey(List<int> seed) {
  if (seed.length != 32) throw ArgumentError('Ed25519 seed must be 32 bytes');
  return _encodePoint(_multiply(_clampedScalar(_sha512(seed)), _base));
}

/// Deterministic 64-byte signature (RFC 8032 §5.1.6).
Uint8List ed25519Sign(List<int> seed, List<int> message) {
  if (seed.length != 32) throw ArgumentError('Ed25519 seed must be 32 bytes');
  final hash = _sha512(seed);
  final a = _clampedScalar(hash);
  final prefix = hash.sublist(32);
  final publicKey = _encodePoint(_multiply(a, _base));
  final r = _littleEndian(_sha512([...prefix, ...message])) % _order;
  final encodedR = _encodePoint(_multiply(r, _base));
  final k =
      _littleEndian(_sha512([...encodedR, ...publicKey, ...message])) % _order;
  final s = (r + k * a) % _order;
  return Uint8List.fromList([...encodedR, ..._toLittleEndian(s, 32)]);
}

/// Strict verification: canonical encodings, `s < L`, and a public key of
/// prime order (rejects the identity and small-order keys), matching the
/// Android verifier's policy.
bool ed25519Verify(
    List<int> publicKey, List<int> signature, List<int> message) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final s = _littleEndian(signature.sublist(32));
  if (s >= _order) return false;
  final a = _decodePoint(Uint8List.fromList(publicKey));
  final r = _decodePoint(Uint8List.fromList(signature.sublist(0, 32)));
  if (a == null || r == null) return false;
  if (_samePoint(a, _identity) ||
      !_samePoint(_multiply(_order, a), _identity)) {
    return false;
  }
  final k = _littleEndian(
          _sha512([...signature.sublist(0, 32), ...publicKey, ...message])) %
      _order;
  return _samePoint(_multiply(s, _base), _add(r, _multiply(k, a)));
}
