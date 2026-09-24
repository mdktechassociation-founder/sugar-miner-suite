import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal Stratum (mining protocol v1) client over raw TCP.
///
/// This is the payoff of building a real app instead of a web page: a native
/// app opens a TCP socket straight to the pool, so there is no WebSocket proxy
/// in the middle and nobody can see or reroute your shares.
class StratumClient {
  final String host;
  final int port;
  final String wallet;
  final String worker;
  final String password;

  Socket? _socket;
  StreamSubscription? _sub;
  final _buffer = StringBuffer();

  int _id = 0;
  final Map<int, String> _pending = {};

  String? extranonce1;
  int extranonce2Size = 4;
  double difficulty = 1;
  bool authorized = false;

  final _log = StreamController<String>.broadcast();
  final _jobs = StreamController<StratumJob>.broadcast();
  final _difficulties = StreamController<double>.broadcast();
  final _connection = StreamController<StratumState>.broadcast();

  Stream<String> get logs => _log.stream;
  Stream<StratumJob> get jobs => _jobs.stream;
  Stream<double> get difficulties => _difficulties.stream;
  Stream<StratumState> get connection => _connection.stream;

  StratumClient({
    required this.host,
    required this.port,
    required this.wallet,
    this.worker = 'flutter',
    this.password = 'x',
  });

  String get username => worker.isEmpty ? wallet : '$wallet.$worker';

  Future<void> connect() async {
    _connection.add(StratumState.connecting);
    _log.add('Connecting to $host:$port …');
    try {
      final sock = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
      sock.setOption(SocketOption.tcpNoDelay, true);
      _socket = sock;
      _buffer.clear();
      _sub = sock
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen(_onData, onError: _onError, onDone: _onDone);
      _connection.add(StratumState.connected);
      _log.add('TCP connected');
      _call('mining.subscribe', ['sugar-dart-app/1.0']);
      _call('mining.authorize', [username, password]);
    } catch (e) {
      _connection.add(StratumState.disconnected);
      _log.add('connect failed: $e');
      rethrow;
    }
  }

  void _onData(String chunk) {
    _buffer.write(chunk);
    // Stratum is newline-delimited; a TCP read can split a line or deliver
    // several at once, so always keep the partial tail.
    var text = _buffer.toString();
    while (true) {
      final nl = text.indexOf('\n');
      if (nl < 0) break;
      final line = text.substring(0, nl).trim();
      text = text.substring(nl + 1);
      if (line.isNotEmpty) _handleLine(line);
    }
    _buffer
      ..clear()
      ..write(text);
  }

  void _handleLine(String line) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      _log.add('non-JSON from pool: ${line.length > 120 ? line.substring(0, 120) : line}');
      return;
    }

    final id = msg['id'];
    if (id is int) {
      final tag = _pending.remove(id);
      final err = msg['error'];
      if (err != null) {
        _log.add('$tag rejected: $err');
        if (tag == 'mining.submit') _submits.add(SubmitResult(err.toString()));
      } else {
        switch (tag) {
          case 'mining.subscribe':
            final res = msg['result'];
            if (res is List) {
              for (final item in res) {
                if (item is String && RegExp(r'^[0-9a-fA-F]+$').hasMatch(item)) extranonce1 = item;
                if (item is int) extranonce2Size = item;
              }
            }
            _log.add('subscribed — extranonce1=$extranonce1 en2size=$extranonce2Size');
          case 'mining.authorize':
            authorized = msg['result'] == true;
            _log.add(authorized ? 'authorized ✓' : 'authorize FAILED');
          case 'mining.submit':
            _submits.add(const SubmitResult(null));
        }
      }
      return;
    }

    switch (msg['method']) {
      case 'mining.set_difficulty':
        difficulty = (msg['params'][0] as num).toDouble();
        _difficulties.add(difficulty);
        _log.add('pool difficulty $difficulty');
      case 'mining.notify':
        final p = (msg['params'] as List).cast<dynamic>();
        final job = StratumJob.fromParams(p);
        _jobs.add(job);
      case 'mining.set_extranonce':
        extranonce1 = msg['params'][0] as String;
        extranonce2Size = (msg['params'][1] as int?) ?? extranonce2Size;
        _log.add('extranonce1 re-issued: $extranonce1');
      case 'mining.ping':
        _send({'id': null, 'method': 'mining.pong', 'params': msg['params'] ?? []});
      case 'client.reconnect':
        _log.add('pool asked us to reconnect: ${msg['params']}');
    }
  }

  final _submits = StreamController<SubmitResult>.broadcast();
  Stream<SubmitResult> get submits => _submits.stream;

  void _onError(Object e) {
    _log.add('socket error: $e');
    _connection.add(StratumState.disconnected);
  }

  void _onDone() {
    _log.add('socket closed by pool');
    _connection.add(StratumState.disconnected);
  }

  int _call(String method, List<dynamic> params) {
    final id = ++_id;
    _pending[id] = method;
    _send({'id': id, 'method': method, 'params': params});
    return id;
  }

  void _send(Map<String, dynamic> obj) {
    final s = _socket;
    if (s == null) return;
    try {
      s.write('${jsonEncode(obj)}\n');
    } catch (e) {
      _log.add('write failed: $e');
    }
  }

  /// Submit a share. Parameter order matters to NOMP-family pools:
  /// [worker, jobId, extranonce2, nTime, nonce] — a swap gets "ntime out of range".
  void submit(StratumJob job, String extranonce2Hex, int nonce) {
    _call('mining.submit', [
      username,
      job.jobId,
      extranonce2Hex,
      job.ntime, // exactly as delivered
      nonce.toRadixString(16).padLeft(8, '0'),
    ]);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
    await _log.close();
    await _jobs.close();
    await _difficulties.close();
    await _connection.close();
    await _submits.close();
  }
}

enum StratumState { disconnected, connecting, connected }

class SubmitResult {
  final String? error;
  const SubmitResult(this.error);
  bool get accepted => error == null;
}

class StratumJob {
  final String jobId;
  final Uint8List prevHash; // header order
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

  /// NOMP sends `reverseByteOrder(previousblockhash)`: every 4-byte word flipped.
  /// Undoing it (the same swap — it is an involution) recovers the bytes that
  /// belong in the 80-byte header.
  static Uint8List _unswapPrevHash(String hex) {
    final b = _hex(hex);
    final out = Uint8List(b.length);
    for (var i = 0; i + 3 < b.length; i += 4) {
      out[i] = b[i + 3];
      out[i + 1] = b[i + 2];
      out[i + 2] = b[i + 1];
      out[i + 3] = b[i];
    }
    return out;
  }

  factory StratumJob.fromParams(List<dynamic> p) => StratumJob(
        jobId: p[0] as String,
        prevHash: _unswapPrevHash(p[1] as String),
        coinb1: p[2] as String,
        coinb2: p[3] as String,
        branches: (p[4] as List).cast<String>(),
        version: p[5] as String,
        nbits: p[6] as String,
        ntime: p[7] as String,
        cleanJobs: p.length > 8 ? p[8] == true : true,
      );

  static Uint8List _hex(String s) {
    final h = s.startsWith('0x') ? s.substring(2) : s;
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
