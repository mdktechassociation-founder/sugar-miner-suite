/// BIP-32: one seed, an endless tree of keys.
///
/// The reason a wallet wants this: a phrase alone can rebuild the key for every
/// address it will ever use, so a backup is twelve words instead of one exported
/// file per key. The derivation rule is HMAC-SHA512 of the parent chain code over
/// the parent key and the index; a hardened index uses the private key, a normal
/// one uses the public key, which is the whole reason hardened levels exist — a
/// hardened level cannot be derived from a public key alone, so a leaked xpub
/// stays harmless below one.
///
/// Extended keys here are serialised with Sugarchain's version bytes, which are
/// the standard xprv/xpub ones (see chainparams.cpp), so an xprv from this app
/// imports into any other Sugarchain wallet's BIP-32 field.
library;

import 'dart:typed_data';

import 'hmac.dart';
import 'sugar_wallet.dart';

/// Where a Sugarchain wallet derives from.
///
/// 44 = BIP-44, 408 = Sugarchain's registered coin type in SLIP-0044, then
/// account 0, external chain, first address. Any wallet that reads SLIP-0044 and
/// has a phrase-restore feature finds the same key at this path; a wallet that
/// does not will still find it if it is told the path.
const String sugarBip44Path = "m/44'/408'/0'/0/0";

class ExtKey {
  final Uint8List key; // 32-byte private key
  final Uint8List chainCode; // 32 bytes
  final int depth;
  final int childIndex;
  final Uint8List parentFingerprint; // 4 bytes

  ExtKey._({
    required this.key,
    required this.chainCode,
    required this.depth,
    required this.childIndex,
    required this.parentFingerprint,
  });

  /// The master key from a seed — "Bitcoin seed" is the BIP-32 constant, used
  /// even by coins that are not Bitcoin.
  static ExtKey master(List<int> seed) {
    final i = HmacSha512.mac('Bitcoin seed'.codeUnits, seed);
    return ExtKey._(
      key: Uint8List.fromList(i.sublist(0, 32)),
      chainCode: Uint8List.fromList(i.sublist(32, 64)),
      depth: 0,
      childIndex: 0,
      parentFingerprint: Uint8List(4),
    );
  }

  Uint8List get publicKey => compressedPubkeyOf(key);
  Uint8List get fingerprint => Uint8List.fromList(hash160Of(publicKey).sublist(0, 4));

  /// Child key at [index]; add [hardened] (0x80000000) for a hardened level.
  ExtKey child(int index, {bool hardened = false}) {
    if (index < 0 || index >= 0x80000000) {
      throw ArgumentError('child index is 0..2^31-1, got $index');
    }
    final i = hardened ? (index + 0x80000000) : index;
    final data = Uint8List(37);
    if (hardened) {
      data[0] = 0x00;
      data.setRange(1, 33, key);
    } else {
      data.setRange(0, 33, publicKey);
    }
    data[33] = (i >>> 24) & 0xff;
    data[34] = (i >>> 16) & 0xff;
    data[35] = (i >>> 8) & 0xff;
    data[36] = i & 0xff;

    final h = HmacSha512.mac(chainCode, data);
    final il = h.sublist(0, 32);
    final ir = h.sublist(32, 64);

    // child = (IL + parent) mod n — the curve order, as a 256-bit big integer
    final n = BigInt.parse(
        'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
        radix: 16);
    final child = (bytesToBigInt(il) + bytesToBigInt(key)) % n;
    if (child == BigInt.zero) {
      // astronomically unlikely; BIP-32 says to move on to the next index
      throw StateError('derived key is zero — use the next index');
    }

    return ExtKey._(
      key: Uint8List.fromList(bigIntBytes(child, 32)),
      chainCode: Uint8List.fromList(ir),
      depth: depth + 1,
      childIndex: i,
      parentFingerprint: fingerprint,
    );
  }

  /// Derives a path like `m/44'/408'/0'/0/0`. `m` alone returns this key.
  ExtKey derive(String path) {
    final parts = path.trim().split('/');
    if (parts.isEmpty || (parts.first != 'm' && parts.first != 'M')) {
      throw const FormatException("a derivation path starts with m, like m/44'/408'/0'/0/0");
    }
    var node = this;
    for (final part in parts.skip(1)) {
      if (part.isEmpty) continue;
      final hardened = part.endsWith("'") || part.endsWith('h') || part.endsWith('H');
      final digits = hardened ? part.substring(0, part.length - 1) : part;
      final index = int.tryParse(digits);
      if (index == null) throw FormatException('not a path component: $part');
      node = node.child(index, hardened: hardened);
    }
    return node;
  }

  /// The 78 bytes both extended keys serialise to, per BIP-32.
  ///
  /// [keyMaterial] is always 33 bytes: the public key for an xpub, and 0x00
  /// followed by the private key for an xprv. That leading zero is not padding —
  /// it is what keeps a 32-byte private key from being mistaken for a public one.
  Uint8List _payload(int version, List<int> keyMaterial) {
    final out = Uint8List(78);
    out[0] = (version >>> 24) & 0xff;
    out[1] = (version >>> 16) & 0xff;
    out[2] = (version >>> 8) & 0xff;
    out[3] = version & 0xff;
    out[4] = depth & 0xff;
    out.setRange(5, 9, parentFingerprint);
    out[9] = (childIndex >>> 24) & 0xff;
    out[10] = (childIndex >>> 16) & 0xff;
    out[11] = (childIndex >>> 8) & 0xff;
    out[12] = childIndex & 0xff;
    out.setRange(13, 45, chainCode);
    out.setRange(45, 78, keyMaterial);
    return out;
  }

  /// `xprv…` — the private extended key. Whoever holds this holds every key
  /// below it, so it belongs in a backup, not in a chat message.
  String toXprv({SugarNetwork? network}) {
    final net = network ?? SugarNetwork.mainnet;
    final marked = Uint8List(33)
      ..[0] = 0x00
      ..setRange(1, 33, key);
    return base58Check(_payload(net.extPrvKey, marked));
  }

  /// `xpub…` — the public extended key: watch, but cannot spend.
  String toXpub({SugarNetwork? network}) {
    final net = network ?? SugarNetwork.mainnet;
    return base58Check(_payload(net.extPubKey, publicKey));
  }

  /// Reads an `xprv…` back. Only the private form: deriving from an xpub needs
  /// point addition on the curve, and this app never has to work from a watch-only
  /// key — importing one would be a feature, not a fix.
  static ExtKey fromXprv(String text, {SugarNetwork? network}) {
    final net = network ?? SugarNetwork.mainnet;
    final decoded = base58CheckDecode(text.trim());
    if (decoded == null || decoded.length != 78) {
      throw const FormatException('that is not an extended key');
    }
    final version = (decoded[0] << 24) | (decoded[1] << 16) | (decoded[2] << 8) | decoded[3];
    if (version == net.extPubKey) {
      throw const FormatException('that is an xpub (watch-only); importing a private key is required to spend');
    }
    if (version != net.extPrvKey) {
      throw FormatException('that extended key is for another network '
          '(version 0x${version.toRadixString(16)})');
    }
    if (decoded[45] != 0x00) {
      throw const FormatException('that xprv is malformed');
    }
    return ExtKey._(
      key: Uint8List.fromList(decoded.sublist(46, 78)),
      chainCode: Uint8List.fromList(decoded.sublist(13, 45)),
      depth: decoded[4],
      childIndex: (decoded[9] << 24) | (decoded[10] << 16) | (decoded[11] << 8) | decoded[12],
      parentFingerprint: Uint8List.fromList(decoded.sublist(5, 9)),
    );
  }
}
