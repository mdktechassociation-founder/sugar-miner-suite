import 'package:shared_preferences/shared_preferences.dart';

/// The version of the disclosure text. Bump this when the wording changes —
/// users are then asked again, because their old "yes" was for different words.
const String kDisclosureVersion = '1.0.0';

/// One recorded "yes" (or the absence of one).
class ConsentRecord {
  final bool granted;
  final String disclosureVersion;
  final DateTime? decidedAt;

  const ConsentRecord({
    required this.granted,
    this.disclosureVersion = '',
    this.decidedAt,
  });

  bool get isCurrent => granted && disclosureVersion == kDisclosureVersion;
}

/// Stores whether this device's owner agreed to let the app mine.
///
/// This is the switch the whole SDK hangs on: [SugarMiner.start] refuses to do
/// anything until [isGranted] returns true, and nothing in the public API can
/// bypass it.
class SugarConsent {
  static const _keyGranted = 'sugar_sdk_consent_granted';
  static const _keyVersion = 'sugar_sdk_consent_version';
  static const _keyWhen = 'sugar_sdk_consent_at';

  static Future<ConsentRecord> read() async {
    final p = await SharedPreferences.getInstance();
    return ConsentRecord(
      granted: p.getBool(_keyGranted) ?? false,
      disclosureVersion: p.getString(_keyVersion) ?? '',
      decidedAt: DateTime.tryParse(p.getString(_keyWhen) ?? ''),
    );
  }

  /// True only when the user said yes to *this* version of the disclosure.
  static Future<bool> isGranted() async {
    final r = await read();
    return r.granted && r.disclosureVersion == kDisclosureVersion;
  }

  static Future<void> grant() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyGranted, true);
    await p.setString(_keyVersion, kDisclosureVersion);
    await p.setString(_keyWhen, DateTime.now().toIso8601String());
  }

  /// The user said no, or changed their mind later. Mining must stop.
  static Future<void> revoke() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyGranted, false);
    await p.remove(_keyVersion);
    await p.remove(_keyWhen);
  }
}
