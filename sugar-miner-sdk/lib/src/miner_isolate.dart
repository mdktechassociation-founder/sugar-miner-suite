import 'dart:async';
import 'dart:isolate';

import 'miner/engine.dart';
import 'miner/stratum.dart';
import 'miner/yespower.dart';
import 'pool_endpoints.dart';
import 'sugar_config.dart';

/// Runs the hashing loop in its own isolate so the host app's UI never stalls,
/// and keeps it going: pools fail over, connections are rebuilt, and the health
/// profiler's changes are applied between batches.
class MinerIsolate {
  final SendPort _cmd;
  final StreamController<MinerSnapshot> _stats = StreamController<MinerSnapshot>.broadcast();
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<bool> _shares = StreamController<bool>.broadcast();
  Isolate? _isolate;

  Stream<MinerSnapshot> get stats => _stats.stream;
  Stream<String> get logs => _logs.stream;
  Stream<bool> get shares => _shares.stream;

  MinerIsolate._(this._cmd);

  static Future<MinerIsolate> spawn({
    required SugarConfig config,
    required MiningPolicy policy,
    required String workerName,
    required void Function(String) onLog,
  }) async {
    final fromChild = ReceivePort();
    final ready = Completer<SendPort>();
    late MinerIsolate iso;

    fromChild.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is _Stats) iso._stats.add(msg.value);
      if (msg is _Log) {
        onLog(msg.value);
        iso._logs.add(msg.value);
      }
      if (msg is _Share) iso._shares.add(msg.value);
      if (msg is _Dead) iso.close();
    });

    final endpoints = (config.endpoints ?? PoolEndpoints.defaults)
        .map((e) => [e.host, e.port, e.label])
        .toList();

    final isolate = await Isolate.spawn(
      _entry,
      _Boot(
        address: config.payoutAddress,
        workerName: workerName,
        endpoints: endpoints,
        cpuSharePercent: policy.cpuSharePercent,
        reply: fromChild.sendPort,
      ),
      debugName: 'sugar-miner-sdk',
      errorsAreFatal: false,
    );

    iso = MinerIsolate._(await ready.future);
    iso._isolate = isolate;
    return iso;
  }

  /// The health profiler's verdict, applied live.
  void applyProfile(double dutyShare, int batchSize) =>
      _cmd.send(['profile', dutyShare, batchSize]);

  Future<void> stop() async {
    _cmd.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await close();
  }

  Future<void> close() async {
    if (!_stats.isClosed) await _stats.close();
    if (!_logs.isClosed) await _logs.close();
    if (!_shares.isClosed) await _shares.close();
  }
}

/* --------------------------------------------------------------- messaging */

class _Boot {
  final String address;
  final String workerName;
  final List<List<dynamic>> endpoints;
  final int cpuSharePercent;
  final SendPort reply;
  const _Boot({
    required this.address,
    required this.workerName,
    required this.endpoints,
    required this.cpuSharePercent,
    required this.reply,
  });
}

class _Stats {
  final MinerSnapshot value;
  const _Stats(this.value);
}

class _Log {
  final String value;
  const _Log(this.value);
}

class _Share {
  final bool value;
  const _Share(this.value);
}

class _Dead {
  const _Dead();
}

Future<void> _entry(_Boot boot) async {
  final inbox = ReceivePort();
  boot.reply.send(inbox.sendPort);

  var running = true;
  inbox.listen((msg) {
    if (msg == 'stop') running = false;
    if (msg is List && msg.isNotEmpty && msg[0] == 'profile') {
      _session?.applyProfile((msg[1] as num).toDouble(), (msg[2] as num).toInt());
    }
  });

  final Yespower yp;
  try {
    yp = Yespower.load();
  } catch (e) {
    inbox.sendPort.send(_Log('native library failed to load: $e'));
    inbox.sendPort.send(const _Dead());
    return;
  }
  inbox.sendPort.send(_Log('engine: ${yp.version}'));

  final rotator = EndpointRotator(
    boot.endpoints
        .map((e) => PoolEndpoint(e[0] as String, e[1] as int, e[2] as String))
        .toList(),
  );

  // Try pools in turn, and keep retrying while we are wanted. A phone that walks
  // out of wifi, or a pool that restarts, must not end the session.
  while (running) {
    final endpoint = rotator.current;
    final client = StratumClient(
      host: endpoint.host,
      port: endpoint.port,
      wallet: boot.address,
      worker: boot.workerName,
      password: rotator.passwordFor(endpoint),
    );
    _session = MiningSession(
      client: client,
      yespower: yp,
      dutyShare: boot.cpuSharePercent / 100.0,
      log: (m) => inbox.sendPort.send(_Log(m)),
      onStats: (s) => inbox.sendPort.send(_Stats(s)),
      onShare: (r) => inbox.sendPort.send(_Share(r.accepted)),
    );

    if (rotator.endpoints.length > 1) {
      inbox.sendPort.send(_Log('pool: ${endpoint.label} (${endpoint.host})'));
    }

    try {
      await _session!.run();
      rotator.reportSuccess();
      await client.dispose();
      break; // asked to stop
    } catch (e) {
      rotator.reportFailure();
      inbox.sendPort.send(_Log('$endpoint failed: $e'));
      await client.dispose();
      if (!running) break;
      final next = rotator.current;
      if (next != endpoint) {
        inbox.sendPort.send(_Log('switching to ${next.label}'));
      } else {
        inbox.sendPort.send(_Log('retrying in 10 s'));
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  yp.freeThreadMemory();
  inbox.sendPort.send(const _Dead());
}

MiningSession? _session;
