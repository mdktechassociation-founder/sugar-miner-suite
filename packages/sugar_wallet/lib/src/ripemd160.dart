/// RIPEMD-160, in Dart, with no dependencies.
///
/// Bitcoin-family chains need it for hash160 = RIPEMD160(SHA256(x)), and Dart's
/// standard library does not have it. Ported from the reference implementation's
/// schedule tables rather than from memory, and checked against the published
/// vectors in the test suite (including the million-'a' case, which is the one
/// that catches rotation and endianness mistakes).
library;

class _Sched {
  static const rl = <List<int>>[
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8],
    [3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12],
    [1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2],
    [4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13],
  ];
  static const rr = <List<int>>[
    [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12],
    [6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2],
    [15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13],
    [8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14],
    [12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11],
  ];
  static const sl = <List<int>>[
    [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8],
    [7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12],
    [11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5],
    [11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12],
    [9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6],
  ];
  static const sr = <List<int>>[
    [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6],
    [9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11],
    [9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5],
    [15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8],
    [8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11],
  ];
  static const kl = <int>[0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e];
  static const kr = <int>[0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000];
}

int _rol(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xffffffff;

class Ripemd160 {
  /// Hashes [input] and returns the 20-byte digest.
  static List<int> digest(List<int> input) {
    final bitLen = input.length * 8;
    final padded = List<int>.filled((((input.length + 9) >> 6) + 1) << 6, 0);
    for (var i = 0; i < input.length; i++) {
      padded[i] = input[i] & 0xff;
    }
    padded[input.length] = 0x80;
    // little-endian length in the last 8 bytes
    final lo = bitLen & 0xffffffff;
    final hi = (bitLen / 0x100000000).floor();
    for (var i = 0; i < 4; i++) {
      padded[padded.length - 8 + i] = (lo >>> (8 * i)) & 0xff;
      padded[padded.length - 4 + i] = (hi >>> (8 * i)) & 0xff;
    }

    var h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
    final x = List<int>.filled(16, 0);

    for (var block = 0; block < padded.length; block += 64) {
      for (var t = 0; t < 16; t++) {
        final i = block + t * 4;
        x[t] = padded[i] | (padded[i + 1] << 8) | (padded[i + 2] << 16) | (padded[i + 3] << 24);
      }
      var al = h0, bl = h1, cl = h2, dl = h3, el = h4;
      var ar = h0, br = h1, cr = h2, dr = h3, er = h4;

      for (var round = 0; round < 5; round++) {
        for (var j = 0; j < 16; j++) {
          final fl = switch (round) {
            0 => bl ^ cl ^ dl,
            1 => (bl & cl) | (~bl & dl),
            2 => (bl | ~cl) ^ dl,
            3 => (bl & dl) | (cl & ~dl),
            _ => bl ^ (cl | ~dl),
          };
          var tl = (al + fl + x[_Sched.rl[round][j]] + _Sched.kl[round]) & 0xffffffff;
          tl = (_rol(tl, _Sched.sl[round][j]) + el) & 0xffffffff;
          al = el;
          el = dl;
          dl = _rol(cl, 10);
          cl = bl;
          bl = tl;

          final fr = switch (round) {
            0 => br ^ (cr | ~dr),
            1 => (br & dr) | (cr & ~dr),
            2 => (br | ~cr) ^ dr,
            3 => (br & cr) | (~br & dr),
            _ => br ^ cr ^ dr,
          };
          var tr = (ar + fr + x[_Sched.rr[round][j]] + _Sched.kr[round]) & 0xffffffff;
          tr = (_rol(tr, _Sched.sr[round][j]) + er) & 0xffffffff;
          ar = er;
          er = dr;
          dr = _rol(cr, 10);
          cr = br;
          br = tr;
        }
      }
      final t = (h1 + cl + dr) & 0xffffffff;
      h1 = (h2 + dl + er) & 0xffffffff;
      h2 = (h3 + el + ar) & 0xffffffff;
      h3 = (h4 + al + br) & 0xffffffff;
      h4 = (h0 + bl + cr) & 0xffffffff;
      h0 = t;
    }

    final out = <int>[];
    for (final h in [h0, h1, h2, h3, h4]) {
      for (var i = 0; i < 4; i++) {
        out.add((h >>> (8 * i)) & 0xff);
      }
    }
    return out;
  }
}
