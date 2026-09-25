import 'dart:typed_data';

/// The web's stand-in for the native yespower core.
///
/// Nothing here hashes. A browser cannot load the C library this engine is built
/// around, so web builds run the wallet and leave mining switched off; the class
/// exists so a mistake shows up as one clear sentence instead of a link error.
class Yespower {
  Yespower._();

  static Yespower load() => throw UnsupportedError(
      'The web build has no yespower core: a browser cannot load the native '
      'library this engine hashes with. Mine from the Android or desktop build.');

  String get version => 'unsupported';

  Uint8List hashHeader(Uint8List header) => throw UnsupportedError('not supported on web');

  ScanResult scan({
    required Uint8List headerPrefix,
    required int startNonce,
    required int count,
    required Uint8List targetBe32,
  }) =>
      throw UnsupportedError('not supported on web');

  /// The real bindings release the per-thread arena here after a batch. There is
  /// no arena on the web, but the engine calls this on every loop, so it has to
  /// exist and has to be harmless.
  void freeThreadMemory() {}
}

class ScanResult {
  final bool hit;
  final int nonce;
  final Uint8List digest;
  final int hashes;

  const ScanResult({
    required this.hit,
    required this.nonce,
    required this.digest,
    required this.hashes,
  });

  /// The pool's own unit: shareDiff = diff1 * 2^16 / value.
  double get poolShareDiff => poolDiff1.toDouble() / _value;

  String get displayHex =>
      digest.reversed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  double get _value {
    var v = BigInt.zero;
    for (var i = 31; i >= 0; i--) {
      v = (v << 8) | BigInt.from(digest[i]);
    }
    if (v == BigInt.zero) return 1;
    return v.toDouble();
  }

  static final BigInt poolDiff1 =
      (BigInt.parse('00000000FFFF0000000000000000000000000000000000000000000000000000', radix: 16)) *
          BigInt.from(65536);
}
