/// HMAC-SHA512 and PBKDF2-HMAC-SHA512.
///
/// BIP-39 turns a word phrase into a seed with PBKDF2-HMAC-SHA512, and BIP-32
/// derives every child key with HMAC-SHA512. Both are here for that reason and
/// nothing else in the wallet needs them.
library;

import 'dart:typed_data';

import 'sha512.dart';

class HmacSha512 {
  static const int _blockSize = 128; // SHA-512 works on 128-byte blocks

  static Uint8List mac(List<int> key, List<int> message) {
    var k = Uint8List.fromList(key);
    // a key longer than the block is hashed first, as the spec says
    if (k.length > _blockSize) k = Sha512.digest(k);
    final padded = Uint8List(_blockSize)..setRange(0, k.length, k);

    final inner = Uint8List(_blockSize + message.length);
    final outer = Uint8List(_blockSize + 64);
    for (var i = 0; i < _blockSize; i++) {
      inner[i] = padded[i] ^ 0x36;
      outer[i] = padded[i] ^ 0x5c;
    }
    inner.setRange(_blockSize, inner.length, message);
    outer.setRange(_blockSize, outer.length, Sha512.digest(inner));
    return Sha512.digest(outer);
  }
}

class Pbkdf2 {
  /// The classic construction: iterate the PRF over the salt and a block index,
  /// XOR the results together, concatenate until enough bytes exist.
  static Uint8List derive({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int length,
    int blockIndex = 1,
  }) {
    final out = Uint8List(length);
    var produced = 0;
    var block = blockIndex;
    while (produced < length) {
      final saltPlusIndex = Uint8List(salt.length + 4)
        ..setRange(0, salt.length, salt);
      saltPlusIndex[salt.length] = (block >>> 24) & 0xff;
      saltPlusIndex[salt.length + 1] = (block >>> 16) & 0xff;
      saltPlusIndex[salt.length + 2] = (block >>> 8) & 0xff;
      saltPlusIndex[salt.length + 3] = block & 0xff;

      var u = HmacSha512.mac(password, saltPlusIndex);
      final acc = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = HmacSha512.mac(password, u);
        for (var j = 0; j < acc.length; j++) {
          acc[j] ^= u[j];
        }
      }
      final take = (length - produced) < acc.length ? (length - produced) : acc.length;
      out.setRange(produced, produced + take, acc);
      produced += take;
      block++;
    }
    return out;
  }
}
