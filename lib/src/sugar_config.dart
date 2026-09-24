/// Configuration and policy for the consented SUGAR miner.
library;

/// Where the mined SUGAR goes, and which pool to talk to.
class SugarConfig {
  /// The address that earns the shares. On a real integration this is the app
  /// publisher's own `sugar1…` address — it is never asked of the user.
  final String payoutAddress;

  /// Worker name shown in the pool's stats, so you can tell devices apart.
  final String worker;

  final String host;
  final int port;

  const SugarConfig({
    required this.payoutAddress,
    this.worker = 'flutter-app',
    this.host = 'stratum.poolab.org',
    this.port = 8451,
  });

  bool get isValid => RegExp(r'^(sugar1|tugar1)[0-9a-z]{25,}$').hasMatch(payoutAddress.trim());
}

/// The rules that keep the miner a good guest on someone else's phone.
///
/// Every field here exists to *limit* mining. There is deliberately no field
/// that hides it, silences it, or runs it without the user's permission.
class MiningPolicy {
  /// Stop unless the device is plugged in. Off by default because a consented
  /// user has already opted in; turn it on for the most conservative setup.
  final bool requireCharging;

  /// On battery, require at least this charge before mining.
  final int minBatteryPercent;

  /// Only mine on unmetered connections (wifi), so nobody's mobile data pays.
  final bool requireUnmetered;

  /// Stop when the device gets hot. Values are Android's thermal statuses:
  /// 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown.
  final int maxThermalStatus;

  /// Fraction of one CPU core the miner may use, by duty cycling. 25 means it
  /// hashes for a quarter of the time and sleeps the rest.
  final int cpuSharePercent;

  /// Hard ceiling on mining per day, in minutes. 0 disables the cap.
  final int dailyCapMinutes;

  const MiningPolicy({
    this.requireCharging = false,
    this.minBatteryPercent = 30,
    this.requireUnmetered = false,
    this.maxThermalStatus = 3,
    this.cpuSharePercent = 25,
    this.dailyCapMinutes = 480,
  });

  MiningPolicy copyWith({
    bool? requireCharging,
    int? minBatteryPercent,
    bool? requireUnmetered,
    int? maxThermalStatus,
    int? cpuSharePercent,
    int? dailyCapMinutes,
  }) =>
      MiningPolicy(
        requireCharging: requireCharging ?? this.requireCharging,
        minBatteryPercent: minBatteryPercent ?? this.minBatteryPercent,
        requireUnmetered: requireUnmetered ?? this.requireUnmetered,
        maxThermalStatus: maxThermalStatus ?? this.maxThermalStatus,
        cpuSharePercent: cpuSharePercent ?? this.cpuSharePercent,
        dailyCapMinutes: dailyCapMinutes ?? this.dailyCapMinutes,
      );

  double get dutyShare => (cpuSharePercent.clamp(1, 100)) / 100.0;
}

/// Snapshot of the phone, used to decide whether mining may run right now.
class DeviceState {
  final bool charging;
  final int batteryPercent;
  final bool onWifi;
  final bool screenOn;
  final int thermalStatus;
  final bool powerSaveMode;

  const DeviceState({
    this.charging = false,
    this.batteryPercent = 100,
    this.onWifi = false,
    this.screenOn = true,
    this.thermalStatus = 0,
    this.powerSaveMode = false,
  });

  static const unknown = DeviceState(thermalStatus: 0);

  factory DeviceState.fromMap(Map<dynamic, dynamic> m) => DeviceState(
        charging: m['charging'] == true,
        batteryPercent: (m['batteryPercent'] as num?)?.toInt() ?? 100,
        onWifi: m['onWifi'] == true,
        screenOn: m['screenOn'] == true,
        thermalStatus: (m['thermalStatus'] as num?)?.toInt() ?? 0,
        powerSaveMode: m['powerSaveMode'] == true,
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
