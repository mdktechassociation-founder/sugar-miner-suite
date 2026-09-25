import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

import 'miner/engine.dart';
import 'miner/stratum.dart';
import 'miner/yespower.dart';
import 'settings.dart';

const _channelId = 'sugar_miner';
const _notificationId = 4242;

/// Configures the Android foreground service. Called from `main()` before the
/// UI is built.
Future<void> configureBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: _channelId,
      initialNotificationTitle: 'SUGAR miner',
      initialNotificationContent: 'Starting the hashing core…',
      foregroundServiceNotificationId: _notificationId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      // iOS does not allow background CPU work; mining there only runs while
      // the app is actually on screen.
      onForeground: (s) async => onServiceStart(s),
      onBackground: (_) async => false,
    ),
  );
}

/// The isolate where mining really happens.
///
/// Running here — inside a foreground service — is what makes the hashing
/// continue with the screen off, which the browser version could never do.
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  void tell(String type, Map<String, dynamic> payload) {
    try {
      service.invoke(type, payload);
    } catch (_) {
      // no UI attached — mining does not care
    }
  }

  void notify(String title, String body) {
    if (service is AndroidServiceInstance) {
      try {
        service.setForegroundNotificationInfo(title: title, content: body);
      } catch (_) {}
    }
  }

  void say(String message) {
    tell('log', {'message': message});
  }

  service.on('stop').listen((_) => service.stopSelf());
  service.on('pause').listen((_) => _live?.pause());
  service.on('resume').listen((_) => _live?.resume());

  final settings = await AppSettings.load();
  if (!AppSettings.isValidAddress(settings.wallet)) {
    say('no payout address set — open the app and enter your sugar1q… address');
    await service.stopSelf();
    return;
  }

  Yespower yespower;
  try {
    yespower = Yespower.load();
  } catch (e) {
    say('the native hashing library failed to load: $e');
    await service.stopSelf();
    return;
  }
  say('engine: ${yespower.version}');

  // Phone networks come and go and pools restart. Reconnect for as long as the
  // service is wanted — a miner that quits on the first hiccup is useless.
  while (true) {
    final client = StratumClient(
      host: settings.host,
      port: settings.port,
      wallet: settings.wallet,
      worker: settings.worker,
    );
    final session = MiningSession(
      client: client,
      yespower: yespower,
      log: say,
      onStats: (s) {
        tell('stats', s.toJson());
        notify(
          'SUGAR miner — ${s.hashrate.toStringAsFixed(1)} H/s',
          'accepted ${s.accepted} · rejected ${s.rejected} · diff '
              '${s.difficulty.toStringAsFixed(2)}',
        );
      },
      onShare: (r) => tell('share', {'accepted': r.accepted, 'error': r.error}),
    );
    _live = session;

    try {
      await session.run();
      await client.dispose();
      break; // asked to stop
    } catch (e) {
      say('disconnected: $e — reconnecting in 10 s');
      notify('SUGAR miner', 'connection lost, retrying…');
      await client.dispose();
      await Future<void>.delayed(const Duration(seconds: 10));
      if (service is AndroidServiceInstance && !await service.isForegroundService()) {
        // Android took the service down; no point looping.
        break;
      }
    }
  }

  say('mining stopped');
  await service.stopSelf();
}

MiningSession? _live;
