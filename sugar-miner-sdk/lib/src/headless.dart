import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import 'sugar_config.dart';

/// The bridge between the app's Dart code and the Android side that wakes the
/// miner after a restart.
///
/// The app defines one entrypoint and tells the SDK about it:
///
/// ```dart
/// @pragma('vm:entry-point')
/// void sugarMinerHeadless() {
///   WidgetsFlutterBinding.ensureInitialized();
///   SugarMinerSdk.install(config: kConfig);
/// }
///
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
///   await SugarMinerSdk.install(config: kConfig);
///   runApp(const MyApp());
/// }
/// ```
///
/// Registering is what makes "mining continues after a restart" real. Without it
/// the SDK does not pretend: the boot receiver does nothing at all, and the app
/// simply mines while it is opened.
class HeadlessEntrypoint {
  /// The Dart callback handle, stored where the Android receiver can read it.
  /// On Android the `shared_preferences` plugin writes keys prefixed with
  /// `flutter.` into the `FlutterSharedPreferences` file — the same place
  /// `SugarMiningService` reads the consent flags from.
  static const String _keyCallback = 'sugar_sdk_boot_callback';

  /// Registers the app's headless entrypoint. Call it in `main()`.
  static Future<bool> register(Function entrypoint) async {
    final handle = PluginUtilities.getCallbackHandle(entrypoint);
    if (handle == null) {
      // Happens when the function is not annotated @pragma('vm:entry-point') or
      // was tree-shaken out of a release build — say so rather than half-working.
      return false;
    }
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyCallback, handle.toRawHandle());
    return true;
  }

  /// True when an entrypoint has been registered on this device.
  static Future<bool> isRegistered() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyCallback) ?? 0) > 0;
  }
}

/// Keeps the Android side's view of the user's decision in sync.
///
/// The boot receiver has to decide whether mining may resume *before* Dart is
/// running, so the two facts it needs are mirrored into preferences it can read:
/// whether consent was given, and whether the user stopped mining themselves.
/// Dart remains the source of truth; this is a copy, written whenever the real
/// value changes and never independently.
class ConsentMirror {
  static const _keyGranted = 'sugar_sdk_consent_granted';
  static const _keyStopped = 'sugar_sdk_user_stopped';

  static Future<void> setGranted(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyGranted, value);
  }

  static Future<void> setStopped(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyStopped, value);
  }

  static Future<bool> granted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyGranted) ?? false;
  }

  static Future<bool> stopped() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyStopped) ?? false;
  }
}

/// Utility used by the install step to decide whether a restart could ever bring
/// the miner back, so the app can tell the user the truth in its own UI.
Future<String> restartBehaviour({required MiningPolicy policy}) async {
  final registered = await HeadlessEntrypoint.isRegistered();
  if (!registered) return 'mining stops when the app is closed; no headless entrypoint registered';
  if (await ConsentMirror.stopped()) return 'off — you stopped it, and it will not restart';
  return policy.resumeWhenAppOpens
      ? 'resumes after a restart while your permission stands'
      : 'stays off after a restart';
}
