/// Configuration, policy and device state for the consented SUGAR miner.
library;

import 'disclosure.dart';
import 'notification_style.dart';
import 'pool_endpoints.dart';

/// Everything the *developer* sets. Nothing here is ever asked of the user:
/// the app owner's address and the app's own disclosure go in the code, once.
class SugarConfig {
  /// The app owner's SUGAR address. This is what earns the shares.
  ///
  /// It is a constructor argument with no setter on purpose — there is no API
  /// that lets an app change it at runtime, and the SDK never asks the user for
  /// a wallet. Mining to a wallet typed by someone who does not own the phone is
  /// how people get robbed.
  final String payoutAddress;

  /// Optional pool worker label. When null the SDK generates one per device
  /// (`<app>-android-<4 hex>`) and remembers it, so the owner's miner list stays
  /// readable without configuring anything.
  final String? workerName;

  /// The disclosure the user accepts. Required, for the reasons in that file.
  final MiningDisclosure disclosure;

  /// Pools to try, in order. Null means the SDK's own list with failover.
  final List<PoolEndpoint>? endpoints;

  /// How the notification looks. Its content is the developer's choice; its
  /// existence is not.
  final NotificationStyle notification;

  const SugarConfig({
    required this.payoutAddress,
    required this.disclosure,
    this.workerName,
    this.endpoints,
    this.notification = NotificationStyle.standard,
  });

  bool get isValid =>
      RegExp(r'^(sugar1|tugar1)[0-9a-z]{25,}$').hasMatch(payoutAddress.trim()) && disclosure.isComplete;

  String get appName => disclosure.appName;
}

/// The rules that keep the miner a good guest on someone else's phone.
///
/// Every field limits mining. There is deliberately no field that hides it,
/// silences it, or runs it without the user's permission.
class MiningPolicy {
  /// Fraction of one CPU core the miner may use, averaged. 25 means it hashes for
  /// a quarter of the time. The auto-configurator may go *below* this, never above.
  final int cpuSharePercent;

  /// Stop unless the device is plugged in.
  final bool requireCharging;

  /// On battery, never mine below this charge.
  final int minBatteryPercent;

  /// Only mine on unmetered connections, so nobody's mobile data pays.
  final bool requireUnmetered;

  /// Stop when the phone gets hot. Android thermal statuses:
  /// 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown.
  final int maxThermalStatus;

  /// Hard ceiling on mining per day, in minutes. 0 disables the cap.
  final int dailyCapMinutes;

  /// Let the health checks pick the duty cycle and batch size within
  /// [cpuSharePercent]. Off means it always uses the full agreed budget.
  final bool autoTune;

  /// Mine whenever the app is launched, as long as the user has consented and
  /// has not stopped it themselves. On by default: this is what makes the SDK
  /// behave like a worker instead of a feature that has to be switched on every
  /// time. The disclosure tells the user mining runs in the background, so this
  /// is covered by the agreement they already gave — and a user's own "stop"
  /// always wins over this flag.
  final bool resumeWhenAppOpens;

  /// How many processor cores mining may use, when the phone is comfortable.
  ///
  /// 1 (the default) keeps everything on a single isolate, which is what a host
  /// app wants on a phone someone is using. Raising it spreads the *same*
  /// budget over several cores — it never increases [cpuSharePercent] — and is
  /// for devices that are plugged in and idle: a spare handset, a kiosk, a small
  /// rack of them. Above 1 the SDK also requires charging, a cool phone and
  /// battery above 60%, and drops back to one core the moment that stops being
  /// true.
  final int maxCores;

  /// The smallest duty cycle worth giving a core, as a fraction (0.02 = 2%).
  /// Used to stop a split that would spend more time scheduling than hashing.
  final double minPerCoreDuty;

  const MiningPolicy({
    this.cpuSharePercent = 25,
    this.requireCharging = false,
    this.minBatteryPercent = 30,
    this.requireUnmetered = false,
    this.maxThermalStatus = 3,
    this.dailyCapMinutes = 480,
    this.autoTune = true,
    this.maxCores = 1,
    this.minPerCoreDuty = 0.02,
    this.resumeWhenAppOpens = true,
  });

  MiningPolicy copyWith({
    int? cpuSharePercent,
    bool? requireCharging,
    int? minBatteryPercent,
    bool? requireUnmetered,
    int? maxThermalStatus,
    int? dailyCapMinutes,
    bool? autoTune,
    bool? resumeWhenAppOpens,
  }) =>
      MiningPolicy(
        cpuSharePercent: cpuSharePercent ?? this.cpuSharePercent,
        requireCharging: requireCharging ?? this.requireCharging,
        minBatteryPercent: minBatteryPercent ?? this.minBatteryPercent,
        requireUnmetered: requireUnmetered ?? this.requireUnmetered,
        maxThermalStatus: maxThermalStatus ?? this.maxThermalStatus,
        dailyCapMinutes: dailyCapMinutes ?? this.dailyCapMinutes,
        autoTune: autoTune ?? this.autoTune,
        resumeWhenAppOpens: resumeWhenAppOpens ?? this.resumeWhenAppOpens,
      );

  /// The most CPU the miner may ever average, whatever the profiler decides.
  double get ceilingDutyShare => (cpuSharePercent.clamp(1, 100)) / 100.0;
}

/// Snapshot of the phone, used to decide whether mining may run right now.
class DeviceState {
  final bool charging;
  final int batteryPercent;
  final int batteryTempC;
  final bool onWifi;
  final bool metered;
  final bool screenOn;
  final int thermalStatus;
  final bool powerSaveMode;
  final bool ignoringBatteryOptimizations;

  const DeviceState({
    this.charging = false,
    this.batteryPercent = -1,
    this.batteryTempC = -1,
    this.onWifi = false,
    this.metered = true,
    this.screenOn = true,
    this.thermalStatus = 0,
    this.powerSaveMode = false,
    this.ignoringBatteryOptimizations = false,
  });

  static const unknown = DeviceState();

  factory DeviceState.fromMap(Map<dynamic, dynamic> m) => DeviceState(
        charging: m['charging'] == true,
        batteryPercent: (m['batteryPercent'] as num?)?.toInt() ?? -1,
        batteryTempC: (m['batteryTempC'] as num?)?.toInt() ?? -1,
        onWifi: m['onWifi'] == true,
        metered: m['metered'] != false,
        screenOn: m['screenOn'] == true,
        thermalStatus: (m['thermalStatus'] as num?)?.toInt() ?? 0,
        powerSaveMode: m['powerSaveMode'] == true,
        ignoringBatteryOptimizations: m['ignoringBatteryOptimizations'] == true,
      );

  String get thermalLabel => const [
        'none',
        'light',
        'moderate',
        'severe',
        'critical',
        'emergency',
        'shutdown',
      ][thermalStatus.clamp(0, 6)];
}

/// Why mining is allowed, or why it is not.
class PolicyDecision {
  final bool allowed;
  final String reason;
  const PolicyDecision(this.allowed, this.reason);

  static const ok = PolicyDecision(true, 'ok');
}

/// Result of asking the miner to start.
class MinerStartResult {
  final bool started;
  final String detail;
  const MinerStartResult(this.started, this.detail);

  @override
  String toString() => started ? 'started ($detail)' : 'not started: $detail';
}
