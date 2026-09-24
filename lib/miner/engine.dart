import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'stratum.dart';
import 'yespower.dart';

/// The mining loop, written as a plain class so it can run on *any* isolate:
/// the UI uses it inside a spawned isolate, and the Android foreground service
/// uses the very same class in its own long-lived isolate.
class MiningSession {
  final StratumClient client;
  final Yespower yespower;

  int hashes = 0;
  int sharesFound = 0;
  int accepted = 0;
  int rejected = 0;
  double bestShareDiff = 0;
  double hashrate = 0;

  final void Function(String) log;
  final void Function(MinerSnapshot)? onStats;
  final void Function(ShareFound)? onShare;

  StratumJob? _job;
  int _en2 = 0;
  int _nonceBase = 0;
  int _windowHashes = 0;
  DateTime _windowStart = DateTime.now();
  bool running = false;
  bool paused = false;

  static const int batch = 4096;

  MiningSession({
    required this.client,
    required this.yespower,
    required this.log,
    this.onStats,
    this.onShare,
  });

  Future<void> run() async {
    running = true;
    client.logs.listen(log);
    client.jobs.listen((j) => _job = j);
    client.submits.listen((r) {
      if (r.accepted) {
        accepted++;
        log('share ACCEPTED by the pool ✓');
      } else {
        rejected++;
        log('share rejected: ${r.error}');
      }
      onShare?.call(ShareFound(accepted: r.accepted, error: r.error));
    });

    await client.connect();
    log('waiting for the first job…');

    while (running) {
      if (paused || _job == null || client.extranonce1 == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }

      final job = _job!;
      final en2Hex = (_en2 % 8).toRadixString(16).padLeft(client.extranonce2Size * 2, '0');
      final prefix = sugarHeaderPrefix(job, client.extranonce1!, en2Hex);
      final target = sugarShareTarget(client.difficulty);

      final res = yespower.scan(
        headerPrefix: prefix,
        startNonce: _nonceBase,
        count: batch,
        targetBe32: target,
      );

      hashes += res.hashes;
      _windowHashes += res.hashes;
      if (res.poolShareDiff > bestShareDiff) bestShareDiff = res.poolShareDiff;

      if (res.hit) {
        sharesFound++;
        final age = DateTime.now().difference(job.received).inSeconds;
        log('share found  nonce=${res.nonce.toRadixString(16)}  '
            'poolDiff=${res.poolShareDiff.toStringAsFixed(4)}  job age ${age}s');
        client.submit(job, en2Hex, res.nonce);
      }

      _nonceBase += batch;
      if (_nonceBase > 0xFFFFFFFF - batch) {
        _nonceBase = 0;
        _en2++;
      }

      final now = DateTime.now();
      final ms = now.difference(_windowStart).inMilliseconds;
      if (ms >= 500) {
        hashrate = _windowHashes * 1000 / ms;
        _windowStart = now;
        _windowHashes = 0;
        onStats?.call(MinerSnapshot(
          hashrate: hashrate,
          hashes: hashes,
          sharesFound: sharesFound,
          accepted: accepted,
          rejected: rejected,
          bestShareDiff: bestShareDiff,
          difficulty: client.difficulty,
          jobId: job.jobId,
          jobAgeSeconds: now.difference(job.received).inSeconds,
        ));
      }
    }

    yespower.freeThreadMemory();
    await client.dispose();
  }

  void pause() => paused = true;
  void resume() => paused = false;
  void stop() => running = false;
}

class MinerSnapshot {
  final double hashrate;
  final int hashes;
  final int sharesFound;
  final int accepted;
  final int rejected;
  final double bestShareDiff;
  final double difficulty;
  final String? jobId;
  final int jobAgeSeconds;

  const MinerSnapshot({
    this.hashrate = 0,
    this.hashes = 0,
    this.sharesFound = 0,
    this.accepted = 0,
    this.rejected = 0,
    this.bestShareDiff = 0,
    this.difficulty = 0,
    this.jobId,
    this.jobAgeSeconds = 0,
  });

  Map<String, dynamic> toJson() => {
        'hashrate': hashrate,
        'hashes': hashes,
        'sharesFound': sharesFound,
        'accepted': accepted,
        'rejected': rejected,
        'bestShareDiff': bestShareDiff,
        'difficulty': difficulty,
        'jobId': jobId,
        'jobAgeSeconds': jobAgeSeconds,
      };

  factory MinerSnapshot.fromJson(Map<String, dynamic> j) => MinerSnapshot(
        hashrate: (j['hashrate'] as num?)?.toDouble() ?? 0,
        hashes: (j['hashes'] as num?)?.toInt() ?? 0,
        sharesFound: (j['sharesFound'] as num?)?.toInt() ?? 0,
        accepted: (j['accepted'] as num?)?.toInt() ?? 0,
        rejected: (j['rejected'] as num?)?.toInt() ?? 0,
        bestShareDiff: (j['bestShareDiff'] as num?)?.toDouble() ?? 0,
        difficulty: (j['difficulty'] as num?)?.toDouble() ?? 0,
        jobId: j['jobId'] as String?,
        jobAgeSeconds: (j['jobAgeSeconds'] as num?)?.toInt() ?? 0,
      );
}

class ShareFound {
  final bool accepted;
  final String? error;
  const ShareFound({required this.accepted, this.error});
}

/* ------------------------------------------------------- consensus plumbing */

/// 80-byte header prefix: version | prevhash | merkle | ntime | nbits | nonce(0)
/// The nonce field is a placeholder — yp_scan overwrites it for every attempt.
Uint8List sugarHeaderPrefix(StratumJob job, String extranonce1, String extranonce2Hex) {
  final coinbase = concatBytes([
    hexToBytes(job.coinb1),
    hexToBytes(extranonce1),
    hexToBytes(extranonce2Hex),
    hexToBytes(job.coinb2),
  ]);
  var merkle = sha256d(coinbase);
  for (final b in job.branches) {
    merkle = sha256d(concatBytes([merkle, hexToBytes(b)]));
  }

  final out = BytesBuilder();
  // These three come from the pool as the *already serialised* little-endian
  // bytes ("00000020" is version 0x20000000 on the wire). Copy them verbatim —
  // parsing to an int and re-encoding little-endian would reverse them.
  out.add(hexToBytes(job.version));
  out.add(job.prevHash);
  out.add(merkle);
  out.add(hexToBytes(job.ntime));
  out.add(hexToBytes(job.nbits));
  out.add(const [0, 0, 0, 0]);
  return out.toBytes();
}

/// The pool's acceptance threshold as a 32-byte big-endian target.
Uint8List sugarShareTarget(double difficulty) {
  final t = shareTargetBigInt(difficulty);
  final bytes = Uint8List(32);
  var v = t;
  final mask = BigInt.from(0xff);
  for (var i = 31; i >= 0; i--) {
    bytes[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return bytes;
}

BigInt shareTargetBigInt(double difficulty) {
  // poolDiff1 = diff1 * 2^16, diff1 being Bitcoin's difficulty-1 target.
  final poolDiff1 = BigInt.parse(
          '00000000FFFF0000000000000000000000000000000000000000000000000000',
          radix: 16) *
      BigInt.from(65536);
  // work in millionths so the 0.99 accept margin survives without doubles
  final micros = (difficulty * 990000).round();
  final scaled = BigInt.from(micros < 1 ? 1 : micros);
  return (poolDiff1 * BigInt.from(1000000)) ~/ scaled;
}

/// How many hashes, on average, one share takes at this difficulty.
double hashesPerShare(double difficulty) {
  final target = shareTargetBigInt(difficulty);
  if (target <= BigInt.zero) return double.infinity;
  return ((BigInt.one << 256) ~/ target).toDouble();
}

Uint8List hexToBytes(String s) {
  var h = s.startsWith('0x') ? s.substring(2) : s;
  if (h.length.isOdd) h = '0$h';
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// sha256d — the coinbase txid and every merkle step use it. Only a handful of
/// calls per job, so a plain Dart implementation costs nothing measurable.
Uint8List sha256d(Uint8List data) {
  final first = crypto.sha256.convert(data).bytes;
  final second = crypto.sha256.convert(first).bytes;
  return Uint8List.fromList(second);
}

Uint8List concatBytes(List<Uint8List> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}
