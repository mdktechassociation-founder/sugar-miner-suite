/// SHA-512, written out because this package carries no dependencies and
/// because BIP-39 needs it: a word phrase becomes a wallet through
/// PBKDF2-HMAC-SHA512, and nothing else in the wallet stack uses SHA-512 at all.
///
/// Sixty-four-bit arithmetic is done as pairs of 32-bit halves rather than with
/// Dart's 64-bit ints, because those are not 64-bit on the web — `int` is a JS
/// number there, and every op below would quietly be wrong. The wallet app does
/// build for web, so this matters even though most users are on a phone.
library;

import 'dart:typed_data';

class Sha512 {

  // First 64 bits of the fractional parts of the cube roots of the first 80
  // primes. Generated and checked against the published table, not typed in.
  static const List<List<int>> _k = <List<int>>[
  [0x428a2f98, 0xd728ae22], [0x71374491, 0x23ef65cd], [0xb5c0fbcf, 0xec4d3b2f], [0xe9b5dba5, 0x8189dbbc], [0x3956c25b, 0xf348b538],
  [0x59f111f1, 0xb605d019], [0x923f82a4, 0xaf194f9b], [0xab1c5ed5, 0xda6d8118], [0xd807aa98, 0xa3030242], [0x12835b01, 0x45706fbe],
  [0x243185be, 0x4ee4b28c], [0x550c7dc3, 0xd5ffb4e2], [0x72be5d74, 0xf27b896f], [0x80deb1fe, 0x3b1696b1], [0x9bdc06a7, 0x25c71235],
  [0xc19bf174, 0xcf692694], [0xe49b69c1, 0x9ef14ad2], [0xefbe4786, 0x384f25e3], [0x0fc19dc6, 0x8b8cd5b5], [0x240ca1cc, 0x77ac9c65],
  [0x2de92c6f, 0x592b0275], [0x4a7484aa, 0x6ea6e483], [0x5cb0a9dc, 0xbd41fbd4], [0x76f988da, 0x831153b5], [0x983e5152, 0xee66dfab],
  [0xa831c66d, 0x2db43210], [0xb00327c8, 0x98fb213f], [0xbf597fc7, 0xbeef0ee4], [0xc6e00bf3, 0x3da88fc2], [0xd5a79147, 0x930aa725],
  [0x06ca6351, 0xe003826f], [0x14292967, 0x0a0e6e70], [0x27b70a85, 0x46d22ffc], [0x2e1b2138, 0x5c26c926], [0x4d2c6dfc, 0x5ac42aed],
  [0x53380d13, 0x9d95b3df], [0x650a7354, 0x8baf63de], [0x766a0abb, 0x3c77b2a8], [0x81c2c92e, 0x47edaee6], [0x92722c85, 0x1482353b],
  [0xa2bfe8a1, 0x4cf10364], [0xa81a664b, 0xbc423001], [0xc24b8b70, 0xd0f89791], [0xc76c51a3, 0x0654be30], [0xd192e819, 0xd6ef5218],
  [0xd6990624, 0x5565a910], [0xf40e3585, 0x5771202a], [0x106aa070, 0x32bbd1b8], [0x19a4c116, 0xb8d2d0c8], [0x1e376c08, 0x5141ab53],
  [0x2748774c, 0xdf8eeb99], [0x34b0bcb5, 0xe19b48a8], [0x391c0cb3, 0xc5c95a63], [0x4ed8aa4a, 0xe3418acb], [0x5b9cca4f, 0x7763e373],
  [0x682e6ff3, 0xd6b2b8a3], [0x748f82ee, 0x5defb2fc], [0x78a5636f, 0x43172f60], [0x84c87814, 0xa1f0ab72], [0x8cc70208, 0x1a6439ec],
  [0x90befffa, 0x23631e28], [0xa4506ceb, 0xde82bde9], [0xbef9a3f7, 0xb2c67915], [0xc67178f2, 0xe372532b], [0xca273ece, 0xea26619c],
  [0xd186b8c7, 0x21c0c207], [0xeada7dd6, 0xcde0eb1e], [0xf57d4f7f, 0xee6ed178], [0x06f067aa, 0x72176fba], [0x0a637dc5, 0xa2c898a6],
  [0x113f9804, 0xbef90dae], [0x1b710b35, 0x131c471b], [0x28db77f5, 0x23047d84], [0x32caab7b, 0x40c72493], [0x3c9ebe0a, 0x15c9bebc],
  [0x431d67c4, 0x9c100d4c], [0x4cc5d4be, 0xcb3e42b6], [0x597f299c, 0xfc657e2a], [0x5fcb6fab, 0x3ad6faec], [0x6c44198c, 0x4a475817],
  ];

  // Fractional parts of the square roots of the first 8 primes.
  static const List<List<int>> _h0 = <List<int>>[
  [0x6a09e667, 0xf3bcc908],
  [0xbb67ae85, 0x84caa73b],
  [0x3c6ef372, 0xfe94f82b],
  [0xa54ff53a, 0x5f1d36f1],
  [0x510e527f, 0xade682d1],
  [0x9b05688c, 0x2b3e6c1f],
  [0x1f83d9ab, 0xfb41bd6b],
  [0x5be0cd19, 0x137e2179],
  ];

  static Uint8List digest(List<int> input) {
    final msg = Uint8List.fromList(input);
    // pad: 0x80, zeros, then the 128-bit length in bits
    final bitLenLo = msg.length * 8;
    // a message this side of 2^32 bits has a zero high half
    var pad = 128 - ((msg.length + 17) % 128);
    if (pad == 128) pad = 0;
    final total = msg.length + 1 + pad + 16;
    final buf = Uint8List(total);
    buf.setRange(0, msg.length, msg);
    buf[msg.length] = 0x80;
    final lenPos = total - 16;
    // The high half of the 128-bit length stays zero: that is every message
    // below 2^61 bits, and the alternative is arithmetic for a case that cannot
    // occur here. The low half is written out below.
    for (var i = 0; i < 8; i++) {
      buf[lenPos + 15 - i] = (bitLenLo >> (8 * i)) & 0xff;
    }

    final h = List<List<int>>.generate(8, (i) => List<int>.from(_h0[i]));
    final w = List<List<int>>.generate(80, (_) => List<int>.filled(2, 0));

    for (var off = 0; off < total; off += 128) {
      for (var i = 0; i < 16; i++) {
        final b = off + i * 8;
        w[i][0] = (buf[b] << 24) | (buf[b + 1] << 16) | (buf[b + 2] << 8) | buf[b + 3];
        w[i][1] = (buf[b + 4] << 24) | (buf[b + 5] << 16) | (buf[b + 6] << 8) | buf[b + 7];
      }
      for (var i = 16; i < 80; i++) {
        final s0 = _sigma0(w[i - 15]);
        final s1 = _sigma1(w[i - 2]);
        w[i] = _add(_add(w[i - 16], s0), _add(w[i - 7], s1));
      }
      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var i = 0; i < 80; i++) {
        final t1 = _add(_add(_add(hh, _bigSigma1(e)), _add(_ch(e, f, g), _k[i])), w[i]);
        final t2 = _add(_bigSigma0(a), _maj(a, b, c));
        hh = g; g = f; f = e;
        e = _add(d, t1);
        d = c; c = b; b = a;
        a = _add(t1, t2);
      }
      h[0] = _add(h[0], a); h[1] = _add(h[1], b); h[2] = _add(h[2], c); h[3] = _add(h[3], d);
      h[4] = _add(h[4], e); h[5] = _add(h[5], f); h[6] = _add(h[6], g); h[7] = _add(h[7], hh);
    }

    final out = Uint8List(64);
    for (var i = 0; i < 8; i++) {
      out[i * 8] = (h[i][0] >>> 24) & 0xff;
      out[i * 8 + 1] = (h[i][0] >>> 16) & 0xff;
      out[i * 8 + 2] = (h[i][0] >>> 8) & 0xff;
      out[i * 8 + 3] = h[i][0] & 0xff;
      out[i * 8 + 4] = (h[i][1] >>> 24) & 0xff;
      out[i * 8 + 5] = (h[i][1] >>> 16) & 0xff;
      out[i * 8 + 6] = (h[i][1] >>> 8) & 0xff;
      out[i * 8 + 7] = h[i][1] & 0xff;
    }
    return out;
  }

  // ── 64-bit ops on [hi, lo] pairs ──────────────────────────────────────────
  static List<int> _add(List<int> a, List<int> b) {
    final lo = a[1] + b[1];
    return [(a[0] + b[0] + (lo >>> 32)) & 0xffffffff, lo & 0xffffffff];
  }

  static List<int> _rotr(List<int> x, int n) {
    final hi = x[0], lo = x[1];
    if (n == 32) return [lo, hi]; // a shift by the word size is not `<< 32` here
    if (n < 32) {
      return [
        ((hi >>> n) | (lo << (32 - n))) & 0xffffffff,
        ((lo >>> n) | (hi << (32 - n))) & 0xffffffff,
      ];
    }
    final m = n - 32;
    if (m == 0) return [lo, hi];
    return [
      ((lo >>> m) | (hi << (32 - m))) & 0xffffffff,
      ((hi >>> m) | (lo << (32 - m))) & 0xffffffff,
    ];
  }

  static List<int> _shr(List<int> x, int n) {
    final hi = x[0], lo = x[1];
    if (n >= 64) return [0, 0];
    if (n == 0) return [hi, lo];
    if (n < 32) {
      return [(hi >>> n) & 0xffffffff, ((lo >>> n) | (hi << (32 - n))) & 0xffffffff];
    }
    final m = n - 32;
    if (m == 0) return [0, hi];
    return [0, (hi >>> m) & 0xffffffff];
  }

  static List<int> _xor(List<int> a, List<int> b) =>
      [(a[0] ^ b[0]) & 0xffffffff, (a[1] ^ b[1]) & 0xffffffff];

  static List<int> _and(List<int> a, List<int> b) =>
      [(a[0] & b[0]) & 0xffffffff, (a[1] & b[1]) & 0xffffffff];

  static List<int> _not(List<int> a) =>
      [(~a[0]) & 0xffffffff, (~a[1]) & 0xffffffff];

  static List<int> _ch(List<int> x, List<int> y, List<int> z) =>
      _xor(_and(x, y), _and(_not(x), z));

  static List<int> _maj(List<int> x, List<int> y, List<int> z) =>
      _xor(_xor(_and(x, y), _and(x, z)), _and(y, z));

  static List<int> _bigSigma0(List<int> x) =>
      _xor(_xor(_rotr(x, 28), _rotr(x, 34)), _rotr(x, 39));

  static List<int> _bigSigma1(List<int> x) =>
      _xor(_xor(_rotr(x, 14), _rotr(x, 18)), _rotr(x, 41));

  static List<int> _sigma0(List<int> x) =>
      _xor(_xor(_rotr(x, 1), _rotr(x, 8)), _shr(x, 7));

  static List<int> _sigma1(List<int> x) =>
      _xor(_xor(_rotr(x, 19), _rotr(x, 61)), _shr(x, 6));
}
