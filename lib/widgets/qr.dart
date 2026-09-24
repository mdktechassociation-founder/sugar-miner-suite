/// A QR encoder, in Dart, in one file — so the app can show a scannable address
/// without pulling a dependency into a program that holds a private key.
///
/// Implements the byte-mode subset of ISO/IEC 18004: versions 1–10, error
/// correction level M, which is what an address needs (a `sugar1q…` address is 43
/// characters; version 3 at level M holds 44 bytes, version 4 holds 62, so there
/// is room to spare for the longer testnet and legacy forms).
///
/// The implementation is the textbook one: Reed–Solomon over GF(256), the standard
/// block interleaving, the eight masks scored by the four penalty rules, and the
/// format/version information. It is deliberately small rather than clever, and it
/// is checked against a decoder in the test suite.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class QrCode {
  final List<List<bool>> modules;
  final int size;

  /// Which of the eight masks this symbol carries. Exposed because the test that
  /// compares this encoder against another implementation has to pin the same
  /// mask; it is a property of the symbol, not a setting, so it lives here rather
  /// than in a global that two concurrent encodes could fight over.
  final int mask;

  const QrCode(this.modules, this.size, {this.mask = -1});

  bool at(int x, int y) => x >= 0 && y >= 0 && x < size && y < size && modules[y][x];

  /// Encodes [text] as a QR symbol. Throws if the text is too long for version 10.
  static QrCode encode(String text, {int? forceMask}) {
    final data = Uint8List.fromList(text.codeUnits);
    final version = _smallestVersion(data.length);
    final codewords = _buildCodewords(data, version);
    final matrix = _Matrix(version * 4 + 17);
    _drawFunctionPatterns(matrix, version, 0); // provisional mask, replaced below
    _placeData(matrix, codewords, version);

    if (forceMask != null) {
      final forced = matrix.copy();
      _applyMask(forced, forceMask);
      _drawFormatInfo(forced, forceMask);
      return QrCode(forced.cells, forced.size, mask: forceMask);
    }

    var best = -1;
    var bestScore = 1 << 30;
    _Matrix? winner;
    for (var mask = 0; mask < 8; mask++) {
      final candidate = matrix.copy();
      _applyMask(candidate, mask);
      _drawFormatInfo(candidate, mask);
      final score = _penalty(candidate);
      if (score < bestScore) {
        bestScore = score;
        best = mask;
        winner = candidate;
      }
    }
    return QrCode(winner!.cells, winner.size, mask: best);
  }

  // ── version + bit stream ────────────────────────────────────────────────
  static int _smallestVersion(int byteLength) {
    // (version, level M data codewords) for the versions we support
    const dataCodewords = {1: 16, 2: 28, 3: 44, 4: 64, 5: 86, 6: 108, 7: 124, 8: 154, 9: 182, 10: 216};
    for (var v = 1; v <= 10; v++) {
      final capacityBytes = dataCodewords[v]! - 2; // mode (4 bits) + length (8 bits)
      if (byteLength <= capacityBytes) return v;
    }
    throw ArgumentError('text is too long for this encoder (max ~214 bytes)');
  }

  static List<int> _buildCodewords(Uint8List data, int version) {
    final bits = <int>[];
    void put(int value, int length) {
      for (var i = length - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    put(0x4, 4); // byte mode
    put(data.length, 8); // version 1-9 use an 8-bit length field
    for (final b in data) {
      put(b, 8);
    }

    const dataCodewords = {1: 16, 2: 28, 3: 44, 4: 64, 5: 86, 6: 108, 7: 124, 8: 154, 9: 182, 10: 216};
    final total = dataCodewords[version]!;
    final capacityBits = total * 8;
    // terminator, then pad to a byte, then the standard pad codewords
    put(0, math.min(4, capacityBits - bits.length));
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final bytes = <int>[];
    for (var i = 0; i < bits.length; i += 8) {
      var b = 0;
      for (var j = 0; j < 8; j++) {
        b = (b << 1) | bits[i + j];
      }
      bytes.add(b);
    }
    var pad = true;
    while (bytes.length < total) {
      bytes.add(pad ? 0xEC : 0x11);
      pad = !pad;
    }

    // ── error correction ───────────────────────────────────────────────────
    // Real RS block tables for level M, versions 1-10: each entry is a list of
    // (how many blocks, data codewords in each). The later versions mix block
    // sizes, which is exactly the thing a "one size fits all" shortcut gets wrong.
    final groups = _blockGroups[version]!;
    final eccPerBlock = _eccCodewords[version]!;
    final dataBlocks = <List<int>>[];
    final eccBlocks = <List<int>>[];
    var offset = 0;
    for (final (count, dataLength) in groups) {
      for (var i = 0; i < count; i++) {
        final block = bytes.sublist(offset, offset + dataLength);
        dataBlocks.add(block);
        eccBlocks.add(_reedSolomon(block, eccPerBlock));
        offset += dataLength;
      }
    }
    assert(offset == bytes.length,
        'block tables must account for every data codeword: $offset vs ${bytes.length}');

    // interleave: one codeword from each block in turn, for data then for ecc
    final out = <int>[];
    final maxData = dataBlocks.map((b) => b.length).reduce(math.max);
    for (var i = 0; i < maxData; i++) {
      for (final block in dataBlocks) {
        if (i < block.length) out.add(block[i]);
      }
    }
    for (var i = 0; i < eccPerBlock; i++) {
      for (final block in eccBlocks) {
        if (i < block.length) out.add(block[i]);
      }
    }
    return out;
  }

  /// (blocks, data codewords per block) for level M — ISO/IEC 18004 table 9.
  static const _blockGroups = <int, List<(int, int)>>{
    1: [(1, 16)],
    2: [(1, 28)],
    3: [(1, 44)],
    4: [(2, 32)],
    5: [(2, 43)],
    6: [(4, 27)],
    7: [(4, 31)],
    8: [(2, 38), (2, 39)],
    9: [(3, 36), (2, 37)],
    10: [(4, 43), (1, 44)],
  };

  static const _eccCodewords = {1: 10, 2: 16, 3: 26, 4: 18, 5: 24, 6: 16, 7: 18, 8: 22, 9: 22, 10: 26};

  // ── Reed–Solomon over GF(256), primitive polynomial 0x11D ──────────────
  static final List<int> _exp = _buildExp();
  static final List<int> _log = _buildLog();

  static List<int> _buildExp() {
    final e = List<int>.filled(512, 0);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      e[i] = x;
      x <<= 1;
      if (x & 0x100 != 0) x ^= 0x11D;
    }
    for (var i = 255; i < 512; i++) {
      e[i] = e[i - 255];
    }
    return e;
  }

  static List<int> _buildLog() {
    final l = List<int>.filled(256, 0);
    for (var i = 0; i < 255; i++) {
      l[_exp[i]] = i;
    }
    return l;
  }

  static int _mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _exp[_log[a] + _log[b]];
  }

  static List<int> _reedSolomon(List<int> data, int eccLength) {
    final generator = _generatorPoly(eccLength);
    final result = List<int>.filled(eccLength, 0);
    for (final byte in data) {
      final factor = byte ^ result[0];
      for (var i = 0; i < eccLength - 1; i++) {
        result[i] = result[i + 1] ^ _mul(generator[i], factor);
      }
      result[eccLength - 1] = _mul(generator[eccLength - 1], factor);
    }
    return result;
  }

  static List<int> _generatorPoly(int degree) {
    var poly = <int>[1];
    for (var i = 0; i < degree; i++) {
      final next = List<int>.filled(poly.length + 1, 0);
      for (var j = 0; j < poly.length; j++) {
        next[j] ^= poly[j];
        next[j + 1] ^= _mul(poly[j], _exp[i]);
      }
      poly = next;
    }
    return poly.sublist(1);
  }

  // ── matrix construction ────────────────────────────────────────────────
  static void _drawFunctionPatterns(_Matrix m, int version, int mask) {
    // finder patterns and separators
    for (final (cx, cy) in [(3, 3), (m.size - 4, 3), (3, m.size - 4)]) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final x = cx + dx, y = cy + dy;
          if (x < 0 || y < 0 || x >= m.size || y >= m.size) continue;
          final ring = math.max(dx.abs(), dy.abs());
          m.set(x, y, ring != 2 && ring != 4, reserved: true);
        }
      }
    }
    // timing patterns
    for (var i = 8; i < m.size - 8; i++) {
      m.set(i, 6, i % 2 == 0, reserved: true);
      m.set(6, i, i % 2 == 0, reserved: true);
    }
    // alignment pattern (versions 2+ have exactly one, for the versions we support)
    if (version >= 2) {
      final pos = _alignmentPositions[version]!;
      for (final y in pos) {
        for (final x in pos) {
          if (m.isReserved(x, y)) continue;
          for (var dy = -2; dy <= 2; dy++) {
            for (var dx = -2; dx <= 2; dx++) {
              final ring = math.max(dx.abs(), dy.abs());
              m.set(x + dx, y + dy, ring != 1, reserved: true);
            }
          }
        }
      }
    }
    // the dark module, and the reserved format areas
    m.set(8, m.size - 8, true, reserved: true);
    for (var i = 0; i < 9; i++) {
      if (!m.isReserved(8, i)) m.set(8, i, false, reserved: true);
      if (!m.isReserved(i, 8)) m.set(i, 8, false, reserved: true);
    }
    for (var i = 0; i < 8; i++) {
      if (!m.isReserved(m.size - 1 - i, 8)) m.set(m.size - 1 - i, 8, false, reserved: true);
      if (!m.isReserved(8, m.size - 1 - i)) m.set(8, m.size - 1 - i, false, reserved: true);
    }
    _drawFormatInfo(m, mask);
  }

  static const _alignmentPositions = {2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
    7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50]};

  static void _drawFormatInfo(_Matrix m, int mask) {
    // error correction level M = 00, then three mask bits, then BCH(15,5)
    final data = (0x00 << 3) | mask;
    var rem = data << 10;
    for (var i = 14; i >= 10; i--) {
      if ((rem >> i) & 1 == 1) rem ^= 0x537 << (i - 10);
    }
    final bits = ((data << 10) | rem) ^ 0x5412;
    for (var i = 0; i < 15; i++) {
      // LSB-first: bit 0 is the least significant bit of the 15-bit sequence,
      // and it goes next to the corner. Placing them MSB-first puts the whole
      // sequence in backwards, which scans *sometimes* and fails the rest of the
      // time — the worst possible failure mode for a QR code.
      final bit = (bits >> i) & 1 == 1;
      // top-left, both arms
      if (i < 6) {
        m.set(8, i, bit, reserved: true);
      } else if (i < 8) {
        m.set(8, i + 1, bit, reserved: true);
      } else if (i == 8) {
        m.set(7, 8, bit, reserved: true);
      } else {
        m.set(14 - i, 8, bit, reserved: true);
      }
      // the copy along the other two edges
      if (i < 8) {
        m.set(m.size - 1 - i, 8, bit, reserved: true);
      } else {
        m.set(8, m.size - 15 + i, bit, reserved: true);
      }
    }
  }

  static void _placeData(_Matrix m, List<int> codewords, int version) {
    final bits = <int>[];
    for (final cw in codewords) {
      for (var i = 7; i >= 0; i--) {
        bits.add((cw >> i) & 1);
      }
    }
    var index = 0;
    var upward = true;
    for (var right = m.size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5; // the vertical timing column is skipped
      for (var step = 0; step < m.size; step++) {
        final y = upward ? m.size - 1 - step : step;
        for (final x in [right, right - 1]) {
          if (m.isReserved(x, y)) continue;
          final bit = index < bits.length ? bits[index] == 1 : false;
          m.set(x, y, bit);
          index++;
        }
      }
      upward = !upward;
    }
  }

  static void _applyMask(_Matrix m, int mask) {
    for (var y = 0; y < m.size; y++) {
      for (var x = 0; x < m.size; x++) {
        if (m.isReserved(x, y)) continue;
        final invert = switch (mask) {
          0 => (x + y) % 2 == 0,
          1 => y % 2 == 0,
          2 => x % 3 == 0,
          3 => (x + y) % 3 == 0,
          4 => (y ~/ 2 + x ~/ 3) % 2 == 0,
          5 => (x * y) % 2 + (x * y) % 3 == 0,
          6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
          _ => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
        };
        if (invert) m.cells[y][x] = !m.cells[y][x];
      }
    }
  }

  static int _penalty(_Matrix m) {
    var score = 0;
    // rule 1: runs of five or more
    for (var y = 0; y < m.size; y++) {
      score += _runScore(List.generate(m.size, (x) => m.cells[y][x]));
    }
    for (var x = 0; x < m.size; x++) {
      score += _runScore(List.generate(m.size, (y) => m.cells[y][x]));
    }
    // rule 2: 2x2 blocks
    for (var y = 0; y < m.size - 1; y++) {
      for (var x = 0; x < m.size - 1; x++) {
        final v = m.cells[y][x];
        if (v == m.cells[y][x + 1] && v == m.cells[y + 1][x] && v == m.cells[y + 1][x + 1]) {
          score += 3;
        }
      }
    }
    // rule 3: finder-like patterns (1:1:3:1:1 with four light modules on either
    // side). Both orientations count — 1011101 0000 and 0000 1011101 — and
    // checking only one of them is the classic way to pick a mask that nobody
    // else would have picked.
    const forward = [true, false, true, true, true, false, true, false, false, false, false];
    const backward = [false, false, false, false, true, false, true, true, true, false, true];
    bool matches(List<bool> line, int start, List<bool> pattern) {
      for (var i = 0; i < 11; i++) {
        if (line[start + i] != pattern[i]) return false;
      }
      return true;
    }

    for (var y = 0; y < m.size; y++) {
      for (var x = 0; x <= m.size - 11; x++) {
        final line = m.cells[y];
        if (matches(line, x, forward) || matches(line, x, backward)) score += 40;
      }
    }
    for (var x = 0; x < m.size; x++) {
      final line = List.generate(m.size, (y) => m.cells[y][x]);
      for (var y = 0; y <= m.size - 11; y++) {
        if (matches(line, y, forward) || matches(line, y, backward)) score += 40;
      }
    }
    // rule 4: proportion of dark modules
    var dark = 0;
    for (final row in m.cells) {
      for (final v in row) {
        if (v) dark++;
      }
    }
    final percent = dark * 100 ~/ (m.size * m.size);
    score += ((percent - 50).abs() ~/ 5) * 10;
    return score;
  }

  static int _runScore(List<bool> line) {
    var score = 0;
    var run = 1;
    for (var i = 1; i < line.length; i++) {
      if (line[i] == line[i - 1]) {
        run++;
      } else {
        if (run >= 5) score += run - 2;
        run = 1;
      }
    }
    if (run >= 5) score += run - 2;
    return score;
  }
}

class _Matrix {
  final int size;
  final List<List<bool>> cells;
  final List<List<bool>> _reserved;

  _Matrix(this.size)
      : cells = List.generate(size, (_) => List<bool>.filled(size, false)),
        _reserved = List.generate(size, (_) => List<bool>.filled(size, false));

  bool isReserved(int x, int y) => _reserved[y][x];

  void set(int x, int y, bool value, {bool reserved = false}) {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    cells[y][x] = value;
    if (reserved) _reserved[y][x] = true;
  }

  _Matrix copy() {
    final m = _Matrix(size);
    for (var y = 0; y < size; y++) {
      m.cells[y] = List<bool>.from(cells[y]);
      m._reserved[y] = List<bool>.from(_reserved[y]);
    }
    return m;
  }
}
