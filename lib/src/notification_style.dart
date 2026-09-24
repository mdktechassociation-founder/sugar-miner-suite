/// The notification's words are the app developer's choice; whether the
/// notification exists is not.
///
/// A miner must never be silent, so this class styles the notification but has
/// no way to hide it, delay it, or make it low-importance. If a template is
/// blank the SDK falls back to plain words that mention mining.
class NotificationStyle {
  /// Shown as the notification title. Default: the app's name, then what it is
  /// doing. Placeholders are filled in for you.
  final String titleTemplate;

  /// Shown under the title.
  final String bodyTemplate;

  /// Android drawable name for the small icon (the SDK ships `ic_sugar_miner`).
  final String iconName;

  /// Colour of the small icon, ARGB. 0 leaves it to the system.
  final int colorArgb;

  const NotificationStyle({
    this.titleTemplate = '{app} is mining SUGAR',
    this.bodyTemplate = '{hashrate} H/s · {accepted} accepted · worker {worker}',
    this.iconName = 'ic_sugar_miner',
    this.colorArgb = 0,
  });

  /// The style the SDK uses when the developer says nothing.
  static const standard = NotificationStyle();

  /// Placeholders available in the templates.
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
}

/// Small helper so both the notification and the log stay consistent.
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
        'state': paused ? pauseReason : 'mining',
        'minutes': '$minedMinutesToday',
      };

  static String _short(String a) =>
      a.length <= 10 ? a : '${a.substring(0, 6)}…${a.substring(a.length - 4)}';
}
