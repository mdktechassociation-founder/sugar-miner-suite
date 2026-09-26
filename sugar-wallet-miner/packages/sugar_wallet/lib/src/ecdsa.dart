/// ECDSA over secp256k1, the twelve lines that let a wallet spend.
///
/// Two decisions worth stating, because both are about not losing money:
///
///  * **RFC 6979 nonces.** A signature is only safe if each one uses a different
///    random k, and using one twice leaks the private key to anybody who looks.
///    Deriving k deterministically from the key and the message removes the
///    random-number generator from the equation entirely — there is nothing to
///    repeat and nothing to be unlucky with. It is also what Bitcoin Core does,
///    which is why the vectors below can be compared byte for byte.
///  * **Low-S.** Signatures come out two ways, mirroring s about the curve order.
///    Bitcoin only relays the low one, so a signature that is valid in the
///    abstract can still be rejected by the network. Normalising here means a
///    signed transaction is relayable the first time.
library;

import 'dart:typed_data';

import 'sha256.dart';
import 'sugar_wallet.dart';

/// The curve order, as bytes and as a big integer.
final BigInt _n = BigInt.parse(
    'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
    radix: 16);

BigInt _mod(BigInt a, BigInt m) => ((a % m) + m) % m;

/// Modular inverse by Fermat's little theorem: a^(m-2) mod m, valid because m is
/// prime. Square-and-multiply, so it is O(log m) curve-free arithmetic.
BigInt _modInv(BigInt a, BigInt m) {
  var result = BigInt.one;
  var base = _mod(a, m);
  var e = m - BigInt.two;
  while (e > BigInt.zero) {
    if (e.isOdd) result = _mod(result * base, m);
    base = _mod(base * base, m);
    e >>= 1;
  }
  return result;
}

class Signature {
  final BigInt r;
  final BigInt s;
  const Signature(this.r, this.s);

  /// DER, as Bitcoin expects it: 0x30 len 0x02 r-len r 0x02 s-len s, with a
  /// leading zero byte on any integer whose top bit is set (otherwise it reads
  /// as negative, and the node rejects the transaction).
  Uint8List toDer() {
    final rBytes = _minimal(r);
    final sBytes = _minimal(s);
    final body = <int>[
      0x02, rBytes.length, ...rBytes,
      0x02, sBytes.length, ...sBytes,
    ];
    return Uint8List.fromList([0x30, body.length, ...body]);
  }

  /// The inverse of [toDer] — needed to check a signature that came from
  /// somewhere else (another wallet's, or a vector's), and by the tests that
  /// verify what this package puts on the wire.
  static Signature fromDer(List<int> der) {
    final b = Uint8List.fromList(der);
    if (b.length < 8 || b[0] != 0x30) throw ArgumentError('not a DER signature');
    var i = 2; // 0x30, total length
    BigInt readInt() {
      if (i >= b.length || b[i] != 0x02) throw ArgumentError('expected an INTEGER');
      final len = b[i + 1];
      final value = bytesToBigInt(b.sublist(i + 2, i + 2 + len));
      i += 2 + len;
      return value;
    }

    final r = readInt();
    final s = readInt();
    return Signature(r, s);
  }

  static Uint8List _minimal(BigInt v) {
    final bytes = <int>[];
    var x = v;
    while (x > BigInt.zero) {
      bytes.insert(0, (x & BigInt.from(0xff)).toInt());
      x >>= 8;
    }
    if (bytes.isEmpty) bytes.add(0);
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return Uint8List.fromList(bytes);
  }

  @override
  String toString() =>
      'Signature(r: ${r.toRadixString(16).padLeft(64, '0')}, '
      's: ${s.toRadixString(16).padLeft(64, '0')})';
}

/// Verifies a signature over a 32-byte digest with a 33-byte public key.
///
/// The standard check, written out: w = s⁻¹, u₁ = z·w, u₂ = r·w, and the signature
/// is good when (u₁·G + u₂·Q).x ≡ r (mod n). It is here for one reason — a wallet
/// that signs without ever checking has no way to notice it signed the wrong
/// thing, and this is the check the tests use on the bytes that leave the phone.
bool verifyHash(Uint8List pubkey33, Uint8List msg32, Signature signature) {
  final n = curveOrder;
  final r = signature.r;
  final s = signature.s;
  if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;

  final z = bytesToBigInt(msg32) % n;
  final w = _modInv(s, n);
  final u1 = (z * w) % n;
  final u2 = (r * w) % n;

  final point = pointAdd(multiplyG(u1), multiplyPoint(u2, decodePubkey(pubkey33)));
  if (point == null) return false;
  return _mod(point.x, n) == r;
}

/// HMAC-SHA256, needed by RFC 6979 and by nothing else here.
Uint8List _hmacSha256(List<int> key, List<int> message) {
  var k = Uint8List.fromList(key);
  if (k.length > 64) k = Uint8List.fromList(Sha256.digest(k));
  final padded = Uint8List(64)..setRange(0, k.length, k);
  final inner = Uint8List(64 + message.length);
  final outer = Uint8List(64 + 32);
  for (var i = 0; i < 64; i++) {
    inner[i] = padded[i] ^ 0x36;
    outer[i] = padded[i] ^ 0x5c;
  }
  inner.setRange(64, inner.length, message);
  outer.setRange(64, outer.length, Sha256.digest(inner));
  return Uint8List.fromList(Sha256.digest(outer));
}

/// RFC 6979 deterministic k for secp256k1 with SHA-256.
BigInt _deterministicK(Uint8List msg32, Uint8List priv32) {
  final x = priv32;
  final h1 = _bits2octets(msg32);
  var v = Uint8List(32)..fillRange(0, 32, 0x01);
  var k = Uint8List(32);

  k = _hmacSha256(k, [...v, 0x00, ...x, ...h1]);
  v = _hmacSha256(k, v);
  k = _hmacSha256(k, [...v, 0x01, ...x, ...h1]);
  v = _hmacSha256(k, v);

  while (true) {
    v = _hmacSha256(k, v);
    // qlen == 256 bits, so one HMAC block is exactly k's worth of bits
    final candidate = bytesToBigInt(v);
    if (candidate > BigInt.zero && candidate < _n) return candidate;
    k = _hmacSha256(k, [...v, 0x00]);
    v = _hmacSha256(k, v);
  }
}

/// bits2octets: the message hash, reduced into the field the key lives in.
Uint8List _bits2octets(Uint8List msg32) {
  final z = bytesToBigInt(msg32);
  final zed = _mod(z, _n);
  return Uint8List.fromList(bigIntBytes(zed, 32));
}

/// Signs a 32-byte message hash. Returns the low-S signature.
///
/// [priv32] is the raw 32-byte private key; the caller keeps it, this does not.
Signature signHash(Uint8List priv32, Uint8List msg32) {
  if (priv32.length != 32 || msg32.length != 32) {
    throw ArgumentError('sign needs a 32-byte key and a 32-byte hash');
  }
  final d = bytesToBigInt(priv32);
  if (d <= BigInt.zero || d >= _n) {
    throw ArgumentError('private key is out of range for secp256k1');
  }

  final z = bytesToBigInt(msg32);
  for (var attempt = 0; attempt < 8; attempt++) {
    final k = _deterministicK(msg32, priv32);
    final point = multiplyG(k);
    final r = _mod(point.x, _n);
    if (r == BigInt.zero) continue;

    var s = _mod(_modInv(k, _n) * (z + r * d), _n);
    if (s == BigInt.zero) continue;

    // low-S: the mirror image is equally valid and never relayed
    if (s > _n >> 1) s = _n - s;
    return Signature(r, s);
  }
  throw StateError('could not produce a signature');
}
