/// The notification is the app's, not the SDK's.
///
/// Every visible thing about it is yours: the words, the icon, the colour, and
/// the Android channel it lives in — so it shows up under your app's own name in
/// the user's settings, not under some library's. The SDK's own defaults are
/// plain language on purpose: no hashrate, no pool names, no share counters,
/// because none of that means anything to the person holding the phone.
///
/// What the SDK keeps to itself is three facts, and only because they are what
/// makes this legal rather than malware: the notification exists while mining
/// happens, it cannot be swiped away, and it always offers Stop. Android requires
/// the first anyway — a foreground service without a notification is killed — so
/// there is nothing to configure here, and no API was written to configure it.
class NotificationStyle {
  /// Shown as the notification title. Placeholders are filled in for you.
  final String titleTemplate;

  /// Shown under the title.
  final String bodyTemplate;

  /// Android drawable name for the small icon (the SDK ships `ic_sugar_miner`).
  final String iconName;

  /// Colour of the small icon, ARGB. 0 leaves it to the system.
  final int colorArgb;

  /// The notification channel to post in. Give it your own id and it appears
  /// under your app's branding in Android's notification settings, next to your
  /// other notifications. Changing the id creates a new channel — useful when
  /// you want the wording in Settings to match your app.
  final String channelId;

  /// The channel's name in Android settings, e.g. "Keeping the app free".
  final String channelName;

  /// The channel's description in Android settings.
  final String channelDescription;

  const NotificationStyle({
    this.titleTemplate = '{app} · using your spare power',
    this.bodyTemplate = 'Mining SUGAR for {app}, which keeps it free. Stop any time.',
    this.iconName = 'ic_sugar_miner',
    this.colorArgb = 0,
    this.channelId = 'sugar_miner_sdk',
    this.channelName = 'Keeping the app free',
    this.channelDescription =
        'Shown while this app borrows a little of your phone\'s spare processing power, '
        'which is what keeps it free.',
  });

  /// The SDK's own wording, shown by default.
  static const standard = NotificationStyle();

  /// A ready-made style for the "free app, in exchange for spare computing" model.
  static const donation = NotificationStyle(
    titleTemplate: '{app} · powered by your spare power',
    bodyTemplate: 'Thanks for keeping {app} free. Stop any time.',
    channelName: 'Powered by your device',
    channelDescription:
        'Shown while this app borrows a little spare processing power to stay free.',
  );

  /// Placeholders available in the templates. None of them are used by the
  /// defaults: the numbers belong in your debug screens, not in the user's face.
  static const placeholders = [
    '{app}', '{worker}', '{hashrate}', '{accepted}', '{rejected}',
    '{diff}', '{state}', '{minutes}', '{pool}', '{address}',
  ];

  String title(Map<String, String> values) => _fill(titleTemplate, values);
  String body(Map<String, String> values) => _fill(bodyTemplate, values);

  static String _fill(String template, Map<String, String> values) {
    var out = template;
    values.forEach((k, v) => out = out.replaceAll('{$k}', v));
    // any leftover placeholder becomes a dash rather than showing "{hashrate}"
    return out.replaceAllMapped(RegExp(r'\{[a-z]+\}'), (_) => '–');
  }

  /// Copy with a different channel, for apps that want their own branding there.
  NotificationStyle withChannel({
    required String id,
    required String name,
    String? description,
  }) =>
      NotificationStyle(
        titleTemplate: titleTemplate,
        bodyTemplate: bodyTemplate,
        iconName: iconName,
        colorArgb: colorArgb,
        channelId: id,
        channelName: name,
        channelDescription: description ?? channelDescription,
      );
}

/// Fills the templates from the miner's live numbers.
///
/// These values exist for the app's own UI and logs — the developer's choice to
/// show. Nothing here is required to make mining work, which is why the default
/// notification ignores most of it.
class NotificationValues {
  static Map<String, String> build({
    required String app,
    required String worker,
    required String pool,
    required String address,
    required double hashrate,
    required int accepted,
    required int rejected,
    required double difficulty,
    required bool paused,
    required String pauseReason,
    required int minedMinutesToday,
  }) =>
      {
        'app': app,
        'worker': worker,
        'pool': pool,
        'address': _short(address),
        'hashrate': hashrate.toStringAsFixed(0),
        'accepted': '$accepted',
        'rejected': '$rejected',
        'diff': difficulty.toStringAsFixed(2),
        'state': paused ? pauseReason : 'running',
        'minutes': '$minedMinutesToday',
      };

  static String _short(String a) =>
      a.length <= 10 ? a : '${a.substring(0, 6)}…${a.substring(a.length - 4)}';
}
