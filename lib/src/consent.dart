import 'package:shared_preferences/shared_preferences.dart';

/// Records that the device owner accepted the app's mining disclosure.
///
/// This is the switch the whole SDK hangs on: [SugarMiner.start] refuses to do
/// anything until [isGranted] returns true for the *current* disclosure, and
/// nothing in the public API can bypass it. The consent is stored with the
/// version of the notice and the terms the user saw, so editing the notice or
/// the terms asks the user again instead of silently re-enrolling them.
class SugarConsent {
  static const _keyGranted = 'sugar_sdk_consent_granted';
  static const _keyVersion = 'sugar_sdk_consent_version';
  static const _keyWhen = 'sugar_sdk_consent_at';
  static const _keyUserStopped = 'sugar_sdk_user_stopped';

  static Future<bool> isGranted(String consentVersion) async {
    final p = await SharedPreferences.getInstance();
    return (p.getBool(_keyGranted) ?? false) && (p.getString(_keyVersion) ?? '') == consentVersion;
  }

  static Future<DateTime?> grantedAt() async {
    final p = await SharedPreferences.getInstance();
    return DateTime.tryParse(p.getString(_keyWhen) ?? '');
  }

  static Future<void> grant(String consentVersion) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyGranted, true);
    await p.setString(_keyVersion, consentVersion);
    await p.setString(_keyWhen, DateTime.now().toIso8601String());
    await p.setBool(_keyUserStopped, false);
  }

  /// The user said no, or withdrew later. Mining must stop and must not restart.
  static Future<void> revoke() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyGranted, false);
    await p.remove(_keyVersion);
    await p.remove(_keyWhen);
    await p.setBool(_keyUserStopped, true);
  }

  /// The user pressed "stop" — in the app or on the notification itself.
  /// Stopping means stopped: the miner will not start again by itself.
  static Future<void> markStoppedByUser() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyUserStopped, true);
  }

  static Future<void> clearUserStopped() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyUserStopped, false);
  }

  static Future<bool> wasStoppedByUser() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyUserStopped) ?? false;
  }
}
