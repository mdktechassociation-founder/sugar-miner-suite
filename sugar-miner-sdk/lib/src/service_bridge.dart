import 'package:flutter/services.dart';

import 'platform/host.dart';
import 'sugar_config.dart';

/// Talks to the SDK's Android side: the foreground service (the thing that keeps
/// Dart alive with the screen off), the device-state queries, and the two
/// permission flows a miner actually needs.
class ServiceBridge {
  static const _ch = MethodChannel('sugar_miner_sdk');

  /// What the device says about itself: charging, battery, temperature, wifi,
  /// thermals, battery-saver and whether this app is exempt from optimisation.
  ///
  /// On Android this is the platform's own answer. Everywhere else there are no
  /// sensors to read — the plugin is Android's — so the SDK reports a state that
  /// is **chosen and documented rather than measured**, because guessing the safe
  /// way here would be worse than useless: "unknown battery" reads as "pause", and
  /// a desktop build that pauses forever is a desktop build that does nothing.
  static Future<Map<Object?, Object?>> deviceState() async {
    if (!Host.isAndroid) return desktopLikeState();
    final r = await _ch.invokeMethod<Map<Object?, Object?>>('deviceState');
    return r ?? <Object?, Object?>{};
  }

  /// The stand-in profile for platforms whose battery APIs this SDK does not
  /// have: desktops and iOS.
  ///
  /// Three deliberate readings, each of which a host app can see and disagree
  /// with — they are in [status] as well as here:
  ///
  ///   * `charging: true` — a desktop is mains-powered and a laptop's battery is
  ///     not readable from Dart without another plugin. A laptop on battery will
  ///     therefore mine as though plugged in; the daily cap still applies, and a
  ///     host that cares can set `requireCharging: false` and cap the minutes.
  ///   * `metered: false` — a desktop connection is not a mobile data plan. A
  ///     tethered laptop is the exception, and that is what the daily cap is for.
  ///   * `thermalStatus: 0` — there is no thermal API here. The operating system
  ///     throttles a hot machine on its own, and on iOS the app is suspended
  ///     anyway when it is not on screen.
  static Map<Object?, Object?> desktopLikeState() => const <Object?, Object?>{
        'charging': true,
        'batteryPercent': -1, // unknown, and shown as unknown
        'batteryTempC': -1,
        'onWifi': true,
        'metered': false,
        'screenOn': true,
        'thermalStatus': 0,
        'powerSaveMode': false,
        'ignoringBatteryOptimizations': true, // nothing to be exempt from
      };

  /// The device state as the SDK models it, for callers that want the typed form.
  static Future<DeviceState> state() async => DeviceState.fromMap(await deviceState());

  // ---- permission 1: notifications (Android 13+) ---------------------------

  /// Without a notification the miner cannot run in the background at all, and
  /// this SDK will not mine without one, so this is a hard requirement.
  static Future<bool> requestNotificationPermission() async {
    if (!Host.hasSystemNotification) return true;
    try {
      return await _ch.invokeMethod<bool>('requestNotificationPermission') ?? true;
    } on PlatformException {
      return true; // older Android: nothing to request
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> hasNotificationPermission() async {
    if (!Host.hasSystemNotification) return true;
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
    if (!Host.needsBatteryExemption) return true;
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog that grants it. The user can always say no; mining
  /// then simply runs less reliably.
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Host.needsBatteryExemption) return; // Android-only concept
    await _ch.invokeMethod<void>('requestIgnoreBatteryOptimizations');
  }

  /// For phones whose vendor adds its own "autostart" list (Xiaomi, Oppo, Vivo,
  /// Samsung…) — opens the settings page so the user can allow it there too.
  static Future<void> openBatterySettings() async {
    if (!Host.needsBatteryExemption) return;
    await _ch.invokeMethod<void>('openBatterySettings');
  }

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

  static Future<void> stopForeground() async {
    if (!Host.hasSystemNotification) return;
    await _ch.invokeMethod<void>('stopForeground');
  }

  static Future<bool> isForeground() async {
    if (!Host.hasSystemNotification) return false;
    try {
      return await _ch.invokeMethod<bool>('isForeground') ?? false;
    } catch (_) {
      return false;
    }
  }
}
