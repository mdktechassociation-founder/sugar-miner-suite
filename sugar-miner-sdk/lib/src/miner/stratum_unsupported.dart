import 'dart:async';
import 'dart:typed_data';

/// The web's stand-in for the Stratum client.
///
/// It carries the same public shape as the real client — the same fields, streams
/// and methods, so the engine compiles unchanged — and every call that would talk
/// to a pool throws with one plain sentence. Nothing here reaches a network: a
/// browser cannot speak raw Stratum over TCP, which is exactly why the browser
/// miner in `sugar-miner/` needs its WebSocket bridge.
class StratumClient {
  final String host;
  final int port;
  final String wallet;
  final String worker;
  final String password;

  StratumClient({
    required this.host,
    required this.port,
    required this.wallet,
    this.worker = 'web',
    this.password = 'x',
  });

  /// Same fields the real client keeps, so nothing that reads them has to know
  /// which build it is in.
  String? extranonce1;
  int extranonce2Size = 4;
  double difficulty = 1;
  bool authorized = false;

  StratumState get state => StratumState.disconnected;
  String get username => worker.isEmpty ? wallet : '$wallet.$worker';

  Stream<String> get logs => const Stream<String>.empty();
  Stream<StratumJob> get jobs => const Stream<StratumJob>.empty();
  Stream<double> get difficulties => const Stream<double>.empty();
  Stream<StratumState> get connection => const Stream<StratumState>.empty();
  Stream<SubmitResult> get submits => const Stream<SubmitResult>.empty();

  Future<void> connect() => throw UnsupportedError(_why);
  void submit(StratumJob job, String extranonce2Hex, int nonce) => throw UnsupportedError(_why);
  Future<void> dispose() async {}

  static const _why =
      'A browser cannot open a TCP socket to a mining pool, so the web build does '
      'not mine. The browser miner in sugar-miner/ uses a WebSocket bridge for '
      'exactly this reason; that is a separate program, not this engine.';
}

enum StratumState { disconnected, connecting, connected }

class SubmitResult {
  final String? error;

  const SubmitResult(this.error);

  bool get accepted => error == null;
}

class StratumJob {
  final String jobId;
  final Uint8List prevHash;
  final String coinb1;
  final String coinb2;
  final List<String> branches;
  final String version;
  final String nbits;
  final String ntime;
  final bool cleanJobs;
  final DateTime received;

  StratumJob({
    required this.jobId,
    required this.prevHash,
    required this.coinb1,
    required this.coinb2,
    required this.branches,
    required this.version,
    required this.nbits,
    required this.ntime,
    required this.cleanJobs,
  }) : received = DateTime.now();
}
