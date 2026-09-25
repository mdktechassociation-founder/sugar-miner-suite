import 'dart:async';

import 'miner/engine.dart';
import 'miner/stratum.dart';
import 'miner/yespower.dart';
import 'settings.dart';

/// The mining loop, with everything about *how it is hosted* passed in.
///
/// Android hosts it inside a foreground service, so hashing survives the screen
/// going off. A desktop hosts it inside an isolate, because there is no such
/// service and nothing to keep alive — closing the app stops mining, which is
/// stated rather than hidden. iOS hosts it in the foreground only, because iOS
/// suspends background apps and no notification can hold one awake.
///
/// The loop itself does not know the difference: pools come and go, it reconnects
/// for as long as it is wanted, and it reports through the callbacks it was given.
class MiningCallbacks {
  /// An event to the UI: `stats`, `log`, `share`.
  final void Function(String type, Map<String, dynamic> payload) tell;
  final void Function(String title, String body) notify;
  final void Function(String message) log;

  /// Whether the host still wants this running. Android asks the service; a
  /// desktop asks whether the app is still open.
  final Future<bool> Function() wanted;

  const MiningCallbacks({
    required this.tell,
    required this.notify,
    required this.log,
    required this.wanted,
  });
}

/// Runs until stopped, hashing to the address in settings.
Future<void> runMiningLoop({
  required MiningCallbacks cb,
  required Stream<void> stop,
  required Stream<void> pause,
  required Stream<void> resume,
}) async {
  stop.listen((_) => _live?.stop());
  pause.listen((_) => _live?.pause());
  resume.listen((_) => _live?.resume());

  final settings = await AppSettings.load();
  if (!AppSettings.isValidAddress(settings.wallet)) {
    cb.log('no payout address set — open the app and enter your sugar1q… address');
    return;
  }

  Yespower yespower;
  try {
    yespower = Yespower.load();
  } catch (e) {
    cb.log('the native hashing library failed to load: $e');
    return;
  }
  cb.log('engine: ${yespower.version}');

  // Phone networks come and go and pools restart. Reconnect for as long as the
  // miner is wanted — one that quits on the first hiccup is useless.
  while (await cb.wanted()) {
    final client = StratumClient(
      host: settings.host,
      port: settings.port,
      wallet: settings.wallet,
      worker: settings.worker,
    );
    final session = MiningSession(
      client: client,
      yespower: yespower,
      log: cb.log,
      onStats: (s) {
        cb.tell('stats', s.toJson());
        cb.notify(
          'SUGAR miner — ${s.hashrate.toStringAsFixed(1)} H/s',
          'accepted ${s.accepted} · rejected ${s.rejected} · diff '
              '${s.difficulty.toStringAsFixed(2)}',
        );
      },
      onShare: (r) => cb.tell('share', {'accepted': r.accepted, 'error': r.error}),
    );
    _live = session;

    try {
      await session.run();
      await client.dispose();
      break; // asked to stop
    } catch (e) {
      cb.log('disconnected: $e — reconnecting in 10 s');
      cb.notify('SUGAR miner', 'connection lost, retrying…');
      await client.dispose();
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  cb.log('mining stopped');
}

MiningSession? _live;
