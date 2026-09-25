import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// FFI bindings for `libyespower.so` — the SugarChain yespower 1.0.1 build that
/// ships in `native/yespower/` and is compiled into the APK by CMake.
///
/// All hashing happens in C. Pure-Dart yespower runs at a few hashes per second
/// which is useless for mining; this runs at hundreds to thousands per second
/// per core.
class Yespower {
  final DynamicLibrary _lib;

  // int  yp_hash(const uint8_t *header, size_t len, uint8_t *out32)
  late final _ypHash = _lib
      .lookupFunction<
          Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>),
          int Function(Pointer<Uint8>, int, Pointer<Uint8>)>('yp_hash');

  // int  yp_scan(const uint8_t *header, size_t len, uint32_t start, uint32_t count,
  //              const uint8_t target_be[32], uint32_t *found_nonce, uint8_t *best_hash)
  late final _ypScan = _lib.lookupFunction<
      Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Pointer<Uint8>,
          Pointer<Uint32>, Pointer<Uint8>),
      int Function(Pointer<Uint8>, int, int, int, Pointer<Uint8>,
          Pointer<Uint32>, Pointer<Uint8>)>('yp_scan');

  late final _ypVersion = _lib
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('yp_version');

  late final _ypFreeLocal = _lib
      .lookupFunction<Void Function(), void Function()>('yp_free_local');

  Yespower._(this._lib);

  static Yespower? _instance;

  /// Opens the native library. Tries the Android name first, then the desktop
  /// Concrete paths to try on macOS, derived from where this binary actually is.
  static List<String> _macOsPaths() {
    try {
      final exe = Platform.resolvedExecutable; // …/App.app/Contents/MacOS/App
      final macos = exe.substring(0, exe.lastIndexOf('/'));
      return [
        '@rpath/libyespower.dylib',
        '$macos/../Frameworks/libyespower.dylib',
        '$macos/libyespower.dylib',
      ];
    } catch (_) {
      return const [];
    }
  }

  /// names so the same code can be tested on Linux/macOS during development.
  static Yespower load() {
    if (_instance != null) return _instance!;
    final candidates = [
      'libyespower.so', // Android + Linux: the loader searches the app's own dir
      'yespower.dll', // Windows: likewise, beside the executable
      'libyespower.dylib', // macOS leaf name
      // macOS does not search the executable's directory for a bare name, the way
      // Windows and Linux do. A Flutter .app is laid out with the core in
      // Contents/Frameworks (and, if someone copies it there by hand, next to the
      // binary), so those two paths are tried by name as well.
      if (Platform.isMacOS) ..._macOsPaths(),
    ];
    Object? last;
    for (final name in candidates) {
      try {
        _instance = Yespower._(DynamicLibrary.open(name));
        return _instance!;
      } catch (e) {
        last = e;
      }
    }
    throw StateError(
        'Could not load the yespower native library ($last).\n'
        'If you are running on a desktop, build it first:\n'
        '  cd native/yespower && gcc -O2 -fPIC -shared -o libyespower.so \\\n'
        '      yp_bridge.c yespower-opt.c sha256.c -I.');
  }

  String get version => _ypVersion().toDartString();

  /// Hash a single 80-byte header. Returns the raw 32-byte little-endian digest.
  Uint8List hashHeader(Uint8List header) {
    final h = calloc<Uint8>(header.length);
    final out = calloc<Uint8>(32);
    try {
      h.asTypedList(header.length).setAll(0, header);
      final rc = _ypHash(h, header.length, out);
      if (rc != 0) throw StateError('yespower failed with code $rc');
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      calloc.free(h);
      calloc.free(out);
    }
  }

  /// The workhorse: hash up to [count] nonces starting at [startNonce] and
  /// report whether any beats [targetBe] (32-byte big-endian share target).
  ///
  /// Keeping the loop inside C avoids one FFI round trip per hash and keeps the
  /// header hot in cache.
  ScanResult scan({
    required Uint8List headerPrefix, // 80 bytes, nonce field will be overwritten
    required int startNonce,
    required int count,
    required Uint8List targetBe32,
  }) {
    final h = calloc<Uint8>(headerPrefix.length);
    final target = calloc<Uint8>(32);
    final nonce = calloc<Uint32>(1);
    final best = calloc<Uint8>(32);
    try {
      h.asTypedList(headerPrefix.length).setAll(0, headerPrefix);
      target.asTypedList(32).setAll(0, targetBe32);
      final rc = _ypScan(h, headerPrefix.length, startNonce, count, target, nonce, best);
      if (rc < 0) throw StateError('yespower scan failed');
      return ScanResult(
        hit: rc == 1,
        nonce: nonce.value,
        digest: Uint8List.fromList(best.asTypedList(32)),
        hashes: count,
      );
    } finally {
      calloc.free(h);
      calloc.free(target);
      calloc.free(nonce);
      calloc.free(best);
    }
  }

  /// Release this thread's ~8 MiB yespower arena (call before a worker stops).
  void freeThreadMemory() => _ypFreeLocal();
}

class ScanResult {
  final bool hit;
  final int nonce;
  final Uint8List digest; // little-endian
  final int hashes;

  const ScanResult({
    required this.hit,
    required this.nonce,
    required this.digest,
    required this.hashes,
  });

  /// The pool's own unit: shareDiff = diff1 * 2^16 / value
  double get poolShareDiff => poolDiff1.toDouble() / _value;

  /// Display hash = byte-reversed digest, like every block explorer shows.
  String get displayHex => digest.reversed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// The digest read as a big-endian number (32 bytes is way past double
  /// precision, but the ratio is what matters and that stays accurate enough).
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
