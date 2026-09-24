/// The paper trail that makes this legitimate: the app's own terms, its privacy
/// policy, and one plain sentence that says out loud what the phone will do.
///
/// The SDK requires all four fields. Not because lawyers like forms, but because
/// "the user agreed" has to mean something: the mining has to be written down
/// where the user accepts it, in words they can read, and it has to be revocable.
/// Mining that only exists in a footnote is what gives phone mining its bad name.
class MiningDisclosure {
  /// The app the user installed, e.g. "Sweet Widgets".
  final String appName;

  /// Who earns, e.g. "Sweet Widgets Ltd" — a human- or company-readable name so
  /// the disclosure is not anonymous.
  final String ownerName;

  /// One or two plain sentences, in the app's own words, shown to the user:
  /// this app mines SUGAR while it runs, it uses CPU/battery/network, it is
  /// visible in a notification, and it stops when they say so.
  final String miningNotice;

  /// Version of that notice. Bump it when the words change and users are asked
  /// again — old consent for new words is not consent.
  final String noticeVersion;

  /// Public URL of the terms the user accepts.
  final String termsUrl;

  final String termsVersion;

  /// Public URL of the privacy policy.
  final String privacyUrl;

  const MiningDisclosure({
    required this.appName,
    required this.ownerName,
    required this.miningNotice,
    required this.noticeVersion,
    required this.termsUrl,
    required this.termsVersion,
    required this.privacyUrl,
  });

  /// Everything the SDK needs for a consent record is present and non-empty.
  bool get isComplete =>
      appName.trim().isNotEmpty &&
      ownerName.trim().isNotEmpty &&
      miningNotice.trim().length >= 40 &&
      noticeVersion.trim().isNotEmpty &&
      termsUrl.startsWith('http') &&
      termsVersion.trim().isNotEmpty &&
      privacyUrl.startsWith('http');

  /// What gets stored against the user's "yes". A change to any of it means the
  /// user is asked again rather than silently re-enrolled.
  String get consentVersion => '$noticeVersion|terms:$termsVersion|privacy:$privacyUrl';

  String get plainText => '$miningNotice\n\n'
      'Mining for: $ownerName\n'
      'Terms: $termsUrl (v$termsVersion)\n'
      'Privacy: $privacyUrl';
}
