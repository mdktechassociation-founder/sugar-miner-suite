import 'package:flutter/services.dart';

/// Talks to the SDK's small Android side: the foreground service (which is what
/// keeps Dart alive with the screen off) and the device-state queries.
class ServiceBridge {
  static const _ch = MethodChannel('sugar_miner_sdk');

  /// Android's own view of the device: charging, battery, wifi, thermals.
  static Future<Map<Object?, Object?>> deviceState() async {
    final r = await _ch.invokeMethod<Map<Object?, Object?>>('deviceState');
    return r ?? <Object?, Object?>{};
  }

  /// Ask for POST_NOTIFICATIONS (Android 13+). A miner without a notification
  /// cannot run in the background at all, so this is a hard requirement.
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

  /// Start (or refresh) the always-visible foreground notification.
  static Future<void> startForeground({required String title, required String text}) =>
      _ch.invokeMethod<void>('startForeground', {'title': title, 'text': text});

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

  /// Handy for the "make mining reliable" hint: opens the system screen where
  /// the user whitelists the app from battery optimisation.
  static Future<void> openBatterySettings() =>
      _ch.invokeMethod<void>('openBatterySettings');
}
