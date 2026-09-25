import 'package:flutter/services.dart';

/// Talks to the SDK's Android side: the foreground service (the thing that keeps
/// Dart alive with the screen off), the device-state queries, and the two
/// permission flows a miner actually needs.
class ServiceBridge {
  static const _ch = MethodChannel('sugar_miner_sdk');

  /// Android's own view of the device: charging, battery, temperature, wifi,
  /// thermals, battery-saver and whether this app is exempt from optimisation.
  static Future<Map<Object?, Object?>> deviceState() async {
    final r = await _ch.invokeMethod<Map<Object?, Object?>>('deviceState');
    return r ?? <Object?, Object?>{};
  }

  // ---- permission 1: notifications (Android 13+) ---------------------------

  /// Without a notification the miner cannot run in the background at all, and
  /// this SDK will not mine without one, so this is a hard requirement.
  static Future<bool> requestNotificationPermission() async {
    try {
      return await _ch.invokeMethod<bool>('requestNotificationPermission') ?? true;
    } on PlatformException {
      return true; // older Android: nothing to request
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> hasNotificationPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hasNotificationPermission') ?? true;
    } catch (_) {
      return false;
    }
  }

  // ---- permission 2: battery optimisation exemption -----------------------

  /// True once the user has let this app run without battery optimisation, which
  /// is what stops Android from freezing the miner after a while in the
  /// background. Not a "permission" in the manifest sense — a user setting.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog that grants it. The user can always say no; mining
  /// then simply runs less reliably.
  static Future<void> requestIgnoreBatteryOptimizations() =>
      _ch.invokeMethod<void>('requestIgnoreBatteryOptimizations');

  /// For phones whose vendor adds its own "autostart" list (Xiaomi, Oppo, Vivo,
  /// Samsung…) — opens the settings page so the user can allow it there too.
  static Future<void> openBatterySettings() =>
      _ch.invokeMethod<void>('openBatterySettings');

  // ---- the notification ---------------------------------------------------

  /// Starts the mining notification. The look is entirely the caller's: icon,
  /// colour, and the Android channel it lives in, so it carries the app's own
  /// branding in the user's notification settings.
  ///
  /// There is deliberately no `importance`, `ongoing` or `silent` argument: the
  /// notification has to exist and stay visible for the mining to be allowed, so
  /// exposing a switch for it would be exposing a switch for malware.
  static Future<void> startForeground({
    required String title,
    required String text,
    String iconName = 'ic_sugar_miner',
    int colorArgb = 0,
    String channelId = 'sugar_miner_sdk',
    String channelName = 'Keeping the app free',
    String channelDescription = '',
  }) =>
      _ch.invokeMethod<void>('startForeground', {
        'title': title,
        'text': text,
        'iconName': iconName,
        'colorArgb': colorArgb,
        'channelId': channelId,
        'channelName': channelName,
        'channelDescription': channelDescription,
      });

  static Future<void> updateNotification({
    required String title,
    required String text,
  }) =>
      _ch.invokeMethod<void>('updateNotification', {'title': title, 'text': text});

  static Future<void> stopForeground() => _ch.invokeMethod<void>('stopForeground');

  static Future<bool> isForeground() async {
    try {
      return await _ch.invokeMethod<bool>('isForeground') ?? false;
    } catch (_) {
      return false;
    }
  }
}
