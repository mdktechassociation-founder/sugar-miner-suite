import 'dart:async';
import 'dart:isolate';

import 'miner/engine.dart';
import 'miner/stratum.dart';
import 'miner/yespower.dart';
import 'sugar_config.dart';

/// Runs the hashing loop in its own isolate so the host app's UI never stalls.
///
/// One isolate, one hashing thread, duty-cycled by [MiningPolicy.cpuSharePercent]
/// — this is a guest on someone's phone, not a space heater.
class MinerIsolate {
  final SendPort _cmd;
  final StreamController<MinerSnapshot> _stats = StreamController<MinerSnapshot>.broadcast();
  final StreamController<String> _log = StreamController<String>.broadcast();
  final StreamController<bool> _shares = StreamController<bool>.broadcast();
  Isolate? _isolate;

  Stream<MinerSnapshot> get stats => _stats.stream;
  Stream<String> get logs => _log.stream;
  Stream<bool> get shares => _shares.stream;

  MinerIsolate._(this._cmd);

  /// Starts hashing. [onLog] is called for every line the miner logs.
  static Future<MinerIsolate> spawn({
    required SugarConfig config,
    required MiningPolicy policy,
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
        iso._log.add(msg.value);
      }
      if (msg is _Share) iso._shares.add(msg.value);
      if (msg is _Dead) iso.close();
    });

    final isolate = await Isolate.spawn(
      _entry,
      _Boot(config: config, cpuSharePercent: policy.cpuSharePercent, reply: fromChild.sendPort),
      debugName: 'sugar-miner-sdk',
      errorsAreFatal: false,
    );

    iso = MinerIsolate._(await ready.future);
    iso._isolate = isolate;
    return iso;
  }

  void pause() => _cmd.send('pause');
  void resume() => _cmd.send('resume');

  Future<void> stop() async {
    _cmd.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await close();
  }

  Future<void> close() async {
    if (!_stats.isClosed) await _stats.close();
    if (!_log.isClosed) await _log.close();
    if (!_shares.isClosed) await _shares.close();
  }
}

/* --------------------------------------------------------------- messaging */

class _Boot {
  final SugarConfig config;
  final int cpuSharePercent;
  final SendPort reply;
  const _Boot({required this.config, required this.cpuSharePercent, required this.reply});
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
  inbox.listen((m) {
    if (m == 'stop') running = false;
    if (m == 'pause') _session?.pause();
    if (m == 'resume') _session?.resume();
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

  final client = StratumClient(
    host: boot.config.host,
    port: boot.config.port,
    wallet: boot.config.payoutAddress,
    worker: boot.config.worker,
  );

  _session = MiningSession(
    client: client,
    yespower: yp,
    dutyShare: boot.cpuSharePercent / 100.0,
    log: (m) => inbox.sendPort.send(_Log(m)),
    onStats: (s) => inbox.sendPort.send(_Stats(s)),
    onShare: (r) => inbox.sendPort.send(_Share(r.accepted)),
  );

  try {
    await _session!.run();
  } catch (e) {
    inbox.sendPort.send(_Log('mining stopped: $e'));
  }
  inbox.sendPort.send(const _Dead());
}

MiningSession? _session;
