import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

import 'miner_loop.dart';

const _channelId = 'sugar_miner';
const _notificationId = 4242;

/// Configures the Android foreground service, and the iOS foreground hook. Called
/// from `main()` before the UI is built — and only on those platforms: a desktop
/// has no such service, and pretending otherwise would be the kind of lie this
/// project does not tell.
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

/// The service's side of the miner: it hosts [runMiningLoop] and turns its events
/// into service messages.
///
/// Running here — inside a foreground service — is what makes the hashing
/// continue with the screen off, which the browser version could never do.
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  Future<bool> wanted() async {
    if (service is AndroidServiceInstance) {
      return service.isForegroundService();
    }
    return true; // iOS: the loop runs while the app is on screen
  }

  await runMiningLoop(
    cb: MiningCallbacks(
      tell: (type, payload) {
        try {
          service.invoke(type, payload);
        } catch (_) {
          // no UI attached — mining does not care
        }
      },
      notify: (title, body) {
        if (service is AndroidServiceInstance) {
          try {
            service.setForegroundNotificationInfo(title: title, content: body);
          } catch (_) {}
        }
      },
      log: (message) {
        try {
          service.invoke('log', {'message': message});
        } catch (_) {}
      },
      wanted: wanted,
    ),
    stop: service.on('stop'),
    pause: service.on('pause'),
    resume: service.on('resume'),
  );

  await service.stopSelf();
}
