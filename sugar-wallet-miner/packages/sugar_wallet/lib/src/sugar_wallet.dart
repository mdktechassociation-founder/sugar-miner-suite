/// secp256k1 and the encodings a Sugarchain address needs.
///
/// The curve arithmetic is Dart's BigInt — no native code, no bindings — because
/// the operations required here are tiny: one scalar multiplication per wallet,
/// once, on the device, at wallet-creation time. Mining never touches any of this;
/// it only ever uses the finished address.
///
/// Parameters are Sugarchain's own, read from its `src/chainparams.cpp`:
///   mainnet: bech32_hrp = "sugar",  WIF prefix 0x80, P2PKH 0x3F
///   testnet: bech32_hrp = "tugar",  WIF prefix 0xEF
library;

import 'dart:typed_data';

import 'ripemd160.dart';
import 'sha256.dart';

/// Curve constants.
class _Curve {
  static final BigInt p = BigInt.parse(
      'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f', radix: 16);
  static final BigInt n = BigInt.parse(
      'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', radix: 16);
  static final BigInt gx = BigInt.parse(
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798', radix: 16);
  static final BigInt gy = BigInt.parse(
      '483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8', radix: 16);
}

BigInt _mod(BigInt a, [BigInt? m]) {
  final mod = m ?? _Curve.p;
  final r = a % mod;
  return r.isNegative ? r + mod : r;
}

/// Modular inverse by Fermat's little theorem (p is prime).
BigInt _inv(BigInt a, BigInt m) {
  var r = BigInt.one, b = _mod(a, m), e = m - BigInt.two;
  while (e > BigInt.zero) {
    if (e.isOdd) r = _mod(r * b, m);
    b = _mod(b * b, m);
    e = e >> 1;
  }
  return r;
}

/// A point on the curve, or null for the point at infinity.
class ECPoint {
  final BigInt x;
  final BigInt y;
  const ECPoint(this.x, this.y);
}

ECPoint? _add(ECPoint? a, ECPoint? b) {
  if (a == null) return b;
  if (b == null) return a;
  if (a.x == b.x && _mod(a.y + b.y) == BigInt.zero) return null;
  final BigInt lambda;
  if (a.x == b.x && a.y == b.y) {
    lambda = _mod(BigInt.from(3) * a.x * a.x * _inv(BigInt.two * a.y, _Curve.p));
  } else {
    lambda = _mod((b.y - a.y) * _inv(b.x - a.x, _Curve.p));
  }
  final x3 = _mod(lambda * lambda - a.x - b.x);
  final y3 = _mod(lambda * (a.x - x3) - a.y);
  return ECPoint(x3, y3);
}

ECPoint _mul(BigInt k, ECPoint point) {
  ECPoint? result;
  ECPoint? addend = point;
  while (k > BigInt.zero) {
    if (k.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    k = k >> 1;
  }
  return result!;
}

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String hex) {
  final clean = hex.trim().replaceAll(RegExp(r'^0x', caseSensitive: false), '').replaceAll(RegExp(r'\s'), '');
  if (clean.isEmpty || clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
    throw FormatException('not hex: $hex');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

List<int> bigIntBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  if (x != BigInt.zero) throw StateError('number too large for $length bytes');
  return out;
}

BigInt bytesToBigInt(List<int> b) {
  var v = BigInt.zero;
  for (final byte in b) {
    v = (v << 8) | BigInt.from(byte);
  }
  return v;
}

/// A network's address parameters, from Sugarchain's chainparams.cpp.
class SugarNetwork {
  final String name;
  final String hrp; // bech32 human-readable part
  final int wifPrefix;
  final int p2pkhPrefix;
  final int extPubKey; // BIP-32 extended public key version
  final int extPrvKey; // BIP-32 extended private key version

  const SugarNetwork._(this.name, this.hrp, this.wifPrefix, this.p2pkhPrefix,
      this.extPubKey, this.extPrvKey);

  // All from chainparams.cpp. Sugarchain keeps the *standard* BIP-32 version
  // bytes (xpub/xprv, not a coin-specific pair), which is what makes an extended
  // key from this app importable into other Sugarchain wallets.
  static const mainnet =
      SugarNetwork._('mainnet', 'sugar', 0x80, 0x3f, 0x0488B21E, 0x0488ADE4);
  static const testnet =
      SugarNetwork._('testnet', 'tugar', 0xef, 0x42, 0x043587CF, 0x04358394);

  static SugarNetwork byName(String name) =>
      name == 'testnet' ? testnet : mainnet;
}

/// Every wallet the app can hold. The private key never leaves the device: the
/// mining SDK is given the address only.
class SugarWallet {
  final SugarNetwork network;
  final Uint8List privateKey;
  final Uint8List publicKey; // compressed
  final Uint8List hash160;
  final String address; // bech32 P2WPKH, sugar1q…
  final String legacyAddress; // P2PKH, S…
  final String wif;

  SugarWallet._({
    required this.network,
    required this.privateKey,
    required this.publicKey,
    required this.hash160,
    required this.address,
    required this.legacyAddress,
    required this.wif,
  });

  /// Derives everything from a 32-byte private key.
  factory SugarWallet.fromPrivateKey(List<int> privateKey, {SugarNetwork? network}) {
    final net = network ?? SugarNetwork.mainnet;
    if (privateKey.length != 32) {
      throw ArgumentError('a private key is 32 bytes, got ${privateKey.length}');
    }
    final k = bytesToBigInt(privateKey);
    if (k <= BigInt.zero || k >= _Curve.n) {
      throw ArgumentError('private key is out of range for secp256k1');
    }
    final pub = compressedPubkeyOf(privateKey);
    final h160 = hash160Of(pub);
    final wifPayload = Uint8List(34)
      ..[0] = net.wifPrefix
      ..[33] = 0x01; // compressed marker
    wifPayload.setRange(1, 33, privateKey);

    final p2pkh = Uint8List(21)..[0] = net.p2pkhPrefix;
    p2pkh.setRange(1, 21, h160);

    return SugarWallet._(
      network: net,
      privateKey: Uint8List.fromList(privateKey),
      publicKey: pub,
      hash160: h160,
      address: bech32Encode(net.hrp, 0, h160),
      legacyAddress: base58Check(p2pkh),
      wif: base58Check(wifPayload),
    );
  }

  /// Creates a wallet from the platform's secure random source.
  ///
  /// [random] must be a cryptographically secure source (the app passes
  /// `Random.secure()`); a wallet from a predictable source is not a wallet.
  factory SugarWallet.generate({SugarNetwork? network, required Uint8List Function(int) random}) {
    final net = network ?? SugarNetwork.mainnet;
    for (var attempt = 0; attempt < 64; attempt++) {
      final candidate = random(32);
      final k = bytesToBigInt(candidate);
      if (k > BigInt.zero && k < _Curve.n) {
        return SugarWallet.fromPrivateKey(candidate, network: net);
      }
    }
    throw StateError('could not generate a key');
  }

  /// Reads a WIF or a 64-character hex key, which is what a user will paste.
  factory SugarWallet.import(String text, {SugarNetwork? network}) {
    final net = network ?? SugarNetwork.mainnet;
    final trimmed = text.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(trimmed)) {
      return SugarWallet.fromPrivateKey(fromHex(trimmed), network: net);
    }
    final decoded = base58CheckDecode(trimmed);
    if (decoded == null || decoded.length < 33) {
      throw const FormatException('that is neither a WIF nor a 64-character hex key');
    }
    if (decoded[0] != net.wifPrefix) {
      throw FormatException(
          'that key belongs to another network (prefix 0x${decoded[0].toRadixString(16)})');
    }
    return SugarWallet.fromPrivateKey(decoded.sublist(1, 33), network: net);
  }

  String get privateKeyHex => toHex(privateKey);
  String get wifOrHex => wif;
}

/// The compressed public key for a 32-byte private key.
///
/// Exposed because BIP-32 needs it in the *middle* of deriving a child key, not
/// only when assembling an address at the end.
Uint8List compressedPubkeyOf(List<int> privateKey) {
  final k = bytesToBigInt(privateKey);
  if (k <= BigInt.zero || k >= _Curve.n) {
    throw ArgumentError('private key is out of range for secp256k1');
  }
  final point = _mul(k, ECPoint(_Curve.gx, _Curve.gy));
  final pub = Uint8List(33);
  pub[0] = point.y.isEven ? 0x02 : 0x03;
  pub.setRange(1, 33, bigIntBytes(point.x, 32));
  return pub;
}

/// hash160(x) = RIPEMD160(SHA256(x)).
///
/// Named with the `Of` suffix because `SugarWallet.hash160` is the derived value
/// on a wallet, and a top-level function of the same name would be shadowed by
/// that field inside the class (which is how this got renamed the first time).
Uint8List hash160Of(List<int> data) {
  return Uint8List.fromList(Ripemd160.digest(Sha256.digest(data)));
}

// ─────────────────────────────────────────────────────────────── bech32 ──
const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

int _polymod(List<int> values) {
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= _gen[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String hrp) => [
      ...hrp.codeUnits.map((c) => c >> 5),
      0,
      ...hrp.codeUnits.map((c) => c & 31),
    ];

List<int> _convertBits(List<int> data, int from, int to, bool pad) {
  var acc = 0, bits = 0;
  final out = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) out.add((acc << (to - bits)) & maxv);
  return out;
}

String bech32Encode(String hrp, int witver, List<int> program) {
  final data = [witver, ..._convertBits(program, 8, 5, true)];
  final polymod = _polymod([..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
  final checksum = List.generate(6, (i) => (polymod >> (5 * (5 - i))) & 31);
  return '$hrp'
      '1'
      '${[...data, ...checksum].map((d) => _charset[d]).join()}';
}

class Bech32Result {
  final String hrp;
  final int witver;
  final Uint8List program;
  const Bech32Result(this.hrp, this.witver, this.program);
}

Bech32Result? bech32Decode(String address) {
  if (address.length < 8 || address.length > 90) return null;
  final lower = address.toLowerCase();
  if (address != lower && address != address.toUpperCase()) return null;
  final pos = lower.lastIndexOf('1');
  if (pos < 1 || pos + 7 > lower.length) return null;
  final hrp = lower.substring(0, pos);
  final data = <int>[];
  for (final rune in lower.substring(pos + 1).codeUnits) {
    final v = _charset.indexOf(String.fromCharCode(rune));
    if (v < 0) return null;
    data.add(v);
  }
  if (_polymod([..._hrpExpand(hrp), ...data]) != 1) return null;
  final witver = data[0];
  final prog = _convertBits(data.sublist(1, data.length - 6), 5, 8, false);
  if (prog.length != 20 && prog.length != 32) return null;
  return Bech32Result(hrp, witver, Uint8List.fromList(prog));
}

// ────────────────────────────────────────────────────────── base58check ──
const _b58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

String base58Encode(List<int> bytes) {
  var num = bytesToBigInt(bytes);
  final base = BigInt.from(58);
  var out = '';
  while (num > BigInt.zero) {
    out = _b58[(num % base).toInt()] + out;
    num = num ~/ base;
  }
  for (final b in bytes) {
    if (b == 0) {
      out = '1$out';
    } else {
      break;
    }
  }
  return out;
}

String base58Check(List<int> payload) {
  final checksum = Sha256.digest(Sha256.digest(payload)).sublist(0, 4);
  return base58Encode([...payload, ...checksum]);
}

Uint8List? base58CheckDecode(String input) {
  var num = BigInt.zero;
  final base = BigInt.from(58);
  for (final ch in input.split('')) {
    final i = _b58.indexOf(ch);
    if (i < 0) return null;
    num = num * base + BigInt.from(i);
  }
  var hex = num == BigInt.zero ? '' : num.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final body = fromHex(hex.isEmpty ? '00' : hex);
  final lead = input.length - input.replaceAll(RegExp(r'^1+'), '').length;
  final bytes = Uint8List(lead + body.length);
  bytes.setRange(lead, bytes.length, body);
  if (bytes.length < 5) return null;
  final payload = bytes.sublist(0, bytes.length - 4);
  final checksum = Sha256.digest(Sha256.digest(payload)).sublist(0, 4);
  for (var i = 0; i < 4; i++) {
    if (bytes[payload.length + i] != checksum[i]) return null;
  }
  return Uint8List.fromList(payload);
}

/// The one-line answer to "can this be a mining payout address?".
///
/// Mirrors the SDK's own rule exactly, so the app and the miner can never
/// disagree about whether a wallet is usable.
bool looksLikeSugarAddress(String address) =>
    RegExp(r'^(sugar1|tugar1)[0-9a-z]{25,}$').hasMatch(address.trim());

class AddressCheck {
  final String label;
  final bool? ok; // null = informational
  final String note;
  const AddressCheck(this.label, this.ok, this.note);
}

List<AddressCheck> checkAddress(String address) {
  final rows = <AddressCheck>[];
  final decoded = bech32Decode(address.trim());
  rows.add(AddressCheck('bech32 checksum', decoded != null,
      decoded != null ? 'valid' : 'not a valid bech32 string'));
  if (decoded == null) return rows;
  final known = decoded.hrp == 'sugar' || decoded.hrp == 'tugar';
  rows.add(AddressCheck('network', known,
      decoded.hrp == 'sugar' ? 'SUGAR mainnet' : decoded.hrp == 'tugar' ? 'SUGAR testnet' : 'unknown (${decoded.hrp})'));
  rows.add(AddressCheck('witness version', decoded.witver == 0, 'v${decoded.witver}'));
  rows.add(AddressCheck('program length', decoded.program.length == 20,
      '${decoded.program.length} bytes'));
  rows.add(AddressCheck('the miner accepts it', looksLikeSugarAddress(address), ''));
  return rows;
}
