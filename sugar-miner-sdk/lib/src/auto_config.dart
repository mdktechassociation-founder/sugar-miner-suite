import 'platform/host.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'sugar_config.dart';

/// What the phone looks like right now, in the terms the profiler cares about.
class DeviceHealth {
  final DeviceState raw;
  final int cpuCores;
  final int ramMb;
  final int batteryTempC;

  const DeviceHealth({
    required this.raw,
    this.cpuCores = 4,
    this.ramMb = 2048,
    this.batteryTempC = 30,
  });

  static DeviceHealth of(DeviceState raw) => DeviceHealth(
        raw: raw,
        cpuCores: Host.cpuCores,
        ramMb: _ramMb(),
        batteryTempC: _batteryTempFrom(raw),
      );

  /// A phone is not a server: if it is weak or tiny, work it gently.
  bool get isLowEnd => cpuCores <= 4 || ramMb < 2048;

  static int _ramMb() {
    // /proc/meminfo where it exists (Android, Linux); -1 elsewhere. Read through
    // Host so this file compiles for the web, which has no filesystem.
    final mb = Host.ramMb;
    return mb > 0 ? mb : 2048;
  }

  static int _batteryTempFrom(DeviceState s) {
    // the platform map carries it when available; keeping this defensive means
    // an older host app still gets a sane profile
    return s.batteryTempC;
  }

  @override
  String toString() =>
      'battery ${raw.batteryPercent}%${raw.charging ? ' (charging)' : ''}, '
      'wifi ${raw.onWifi}, screen ${raw.screenOn ? 'on' : 'off'}, '
      'thermal ${raw.thermalLabel}, cores $cpuCores, ram ${ramMb}MB';
}

/// The mining setting the auto-configurator picked, and why.
class MiningProfile {
  /// 'paused' | 'eco' | 'balanced' | 'sprint'
  final String name;

  /// Share of one core (duty cycle) the miner may use right now.
  final double dutyShare;

  /// Nonces per native call — smaller batches react faster to a hot phone.
  final int batch;

  /// Set when mining must not run at all.
  final String? pauseReason;

  /// The device facts the decision was made from. Carried along so the core
  /// scheduler can re-plan from the same reading instead of asking Android again
  /// (and possibly getting a different answer a moment later).
  final bool charging;
  final int thermalStatus;
  final int batteryPercent;

  const MiningProfile({
    required this.name,
    required this.dutyShare,
    required this.batch,
    this.pauseReason,
    this.charging = false,
    this.thermalStatus = 0,
    this.batteryPercent = -1,
  });

  bool get canMine => pauseReason == null;

  static const paused = MiningProfile(name: 'paused', dutyShare: 0, batch: 2048);

  Map<String, dynamic> toJson() =>
      {'name': name, 'dutyShare': dutyShare, 'batch': batch, 'pauseReason': pauseReason};

  @override
  String toString() => canMine ? '$name (${(dutyShare * 100).round()}% of a core)' : 'paused: $pauseReason';
}

/// Turns the phone's current state into a mining setting, and changes it only
/// when the change sticks — a phone that wobbles between wifi and cell must not
/// make the miner flap between running and paused every few seconds.
class AutoConfigurator {
  final MiningPolicy policy;
  final MiningProfile ceilingProfile;

  MiningProfile _current;
  String? _pendingChange;
  int _pendingCount = 0;
  DateTime? _lastChange;

  static const _hysteresisTicks = 3; // three consecutive checks before switching
  static const _minTimeBetweenChanges = Duration(minutes: 2);

  AutoConfigurator({required this.policy})
      : ceilingProfile = MiningProfile(
          name: 'ceiling',
          dutyShare: (policy.cpuSharePercent.clamp(1, 100)) / 100.0,
          batch: 4096,
        ),
        _current = MiningProfile(
          name: 'balanced',
          dutyShare: (policy.cpuSharePercent.clamp(1, 100)) / 100.0,
          batch: 4096,
        );

  MiningProfile get current => _current;

  /// The raw, un-smoothed decision — useful for the UI, not for switching.
  MiningProfile decide(DeviceHealth h) {
    final s = h.raw;
    // Attached to every profile below, so downstream code never has to re-read.
    MiningProfile attach(MiningProfile p) => MiningProfile(
          name: p.name,
          dutyShare: p.dutyShare,
          batch: p.batch,
          pauseReason: p.pauseReason,
          charging: s.charging,
          thermalStatus: s.thermalStatus,
          batteryPercent: s.batteryPercent,
        );

    // ---- hard stops, in the order a user would expect -----------------------
    if (policy.requireCharging && !s.charging) {
      return attach(const MiningProfile(name: 'paused', dutyShare: 0, batch: 2048, pauseReason: 'waiting for the charger'));
    }
    if (!s.charging && s.batteryPercent >= 0 && s.batteryPercent < policy.minBatteryPercent) {
      return attach(MiningProfile(
        name: 'paused',
        dutyShare: 0,
        batch: 2048,
        pauseReason: 'battery ${s.batteryPercent}% is below ${policy.minBatteryPercent}%',
      ));
    }
    if (s.thermalStatus > policy.maxThermalStatus) {
      return attach(MiningProfile(
        name: 'paused',
        dutyShare: 0,
        batch: 2048,
        pauseReason: 'phone is too warm (${s.thermalLabel})',
      ));
    }
    if (policy.requireUnmetered && !s.onWifi) {
      return attach(const MiningProfile(name: 'paused', dutyShare: 0, batch: 2048, pauseReason: 'waiting for wifi'));
    }
    if (s.powerSaveMode && !s.charging) {
      return attach(const MiningProfile(name: 'paused', dutyShare: 0, batch: 2048, pauseReason: 'battery saver is on'));
    }
    if (h.batteryTempC >= 43) {
      return attach(MiningProfile(
        name: 'paused',
        dutyShare: 0,
        batch: 2048,
        pauseReason: 'battery at ${h.batteryTempC}°C',
      ));
    }

    // ---- otherwise: pick how hard to work -----------------------------------
    final ceiling = ceilingProfile.dutyShare;
    final warm = s.thermalStatus >= (policy.maxThermalStatus - 1).clamp(0, 6);
    final lowish = !s.charging && s.batteryPercent >= 0 && s.batteryPercent < 60;

    if (warm || lowish || h.isLowEnd) {
      // Half the agreed budget, small batches so we notice cooling quickly
      return attach(MiningProfile(name: 'eco', dutyShare: ceiling / 2, batch: 2048));
    }
    if (s.charging && s.thermalStatus == 0 && s.batteryPercent >= 80) {
      // plugged in, cool and full: spend the whole agreed budget
      return attach(MiningProfile(name: 'sprint', dutyShare: ceiling, batch: 8192));
    }
    return attach(MiningProfile(name: 'balanced', dutyShare: ceiling, batch: 4096));
  }

  /// The smoothed decision. Returns the profile mining should now use.
  MiningProfile update(DeviceHealth h) {
    // policy violations and "no mining" states apply immediately — never delay a stop
    final wanted = decide(h);
    if (!wanted.canMine) {
      _pendingChange = null;
      _pendingCount = 0;
      _current = wanted;
      return _current;
    }

    if (wanted.name == _current.name) {
      _pendingChange = null;
      _pendingCount = 0;
      return _current;
    }

    // nothing to smooth about starting from paused
    if (!_current.canMine) {
      _current = wanted;
      _lastChange = DateTime.now();
      return _current;
    }

    final now = DateTime.now();
    final cooling = _lastChange != null && now.difference(_lastChange!) < _minTimeBetweenChanges;
    if (cooling) return _current;

    if (_pendingChange != wanted.name) {
      _pendingChange = wanted.name;
      _pendingCount = 1;
      return _current;
    }

    _pendingCount++;
    if (_pendingCount >= _hysteresisTicks) {
      _pendingChange = null;
      _pendingCount = 0;
      _current = wanted;
      _lastChange = now;
    }
    return _current;
  }
}

/// The device's mining identity, so the pool's worker list stays readable.
///
/// Predefined once and then remembered: the app owner never configures it and
/// neither does the user.
class WorkerIdentity {
  static const _keyWorker = 'sugar_sdk_worker_name';

  static Future<String> resolve({required String appSlug, String? configured}) async {
    final p = await SharedPreferences.getInstance();
    if (configured != null && configured.trim().isNotEmpty) {
      await p.setString(_keyWorker, configured.trim());
      return configured.trim();
    }
    final existing = p.getString(_keyWorker);
    if (existing != null && existing.isNotEmpty) return existing;

    // <app>-<android|ios>-<4 hex>, e.g. myapp-android-7f3a
    final slug = appSlug.isEmpty ? 'app' : appSlug.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final tail = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final name = '$slug-${Host.isAndroid ? 'android' : 'device'}-${tail.substring(tail.length - 4)}';
    await p.setString(_keyWorker, name);
    return name;
  }
}
