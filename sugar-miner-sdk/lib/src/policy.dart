import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'auto_config.dart';
import 'service_bridge.dart';
import 'sugar_config.dart';

/// Applies [MiningPolicy] to the actual phone, keeps the daily time budget, and
/// asks [AutoConfigurator] how hard to work right now.
class PolicyEngine {
  final MiningPolicy policy;
  final AutoConfigurator profiler;
  PolicyEngine(this.policy) : profiler = AutoConfigurator(policy: policy);

  static const _keyMinedDay = 'sugar_sdk_mined_day';
  static const _keyMinedSeconds = 'sugar_sdk_mined_seconds';

  /// What Android says about the phone right now.
  Future<DeviceHealth> health() async {
    try {
      final map = await ServiceBridge.deviceState();
      return DeviceHealth.of(DeviceState.fromMap(map));
    } catch (_) {
      return DeviceHealth.of(DeviceState.unknown);
    }
  }

  /// Decide whether mining may run, and how hard. This is the single place that
  /// answers "is the phone in a fit state", used by the start path and by the
  /// watchdog that runs while mining.
  Future<(PolicyDecision, MiningProfile)> evaluate() async {
    if (await SugarConsentStop.isStopped()) {
      return (const PolicyDecision(false, 'you stopped mining'), MiningProfile.paused);
    }

    final h = await health();
    var profile = profiler.update(h);

    if (profile.canMine && policy.dailyCapMinutes > 0) {
      final used = await minedMinutesToday();
      if (used >= policy.dailyCapMinutes) {
        profile = MiningProfile(
          name: 'paused',
          dutyShare: 0,
          batch: profile.batch,
          pauseReason: "today's ${policy.dailyCapMinutes} minute limit is used up",
        );
      }
    }

    final decision = profile.canMine
        ? const PolicyDecision(true, 'ok')
        : PolicyDecision(false, profile.pauseReason ?? 'paused');
    return (decision, profile);
  }

  /// Minutes mined so far today (resets at midnight local time).
  static Future<int> minedMinutesToday() async {
    final p = await SharedPreferences.getInstance();
    final day = DateTime.now().toIso8601String().substring(0, 10);
    if (p.getString(_keyMinedDay) != day) return 0;
    return (p.getInt(_keyMinedSeconds) ?? 0) ~/ 60;
  }

  static Future<void> addMinedSeconds(int seconds) async {
    final p = await SharedPreferences.getInstance();
    final day = DateTime.now().toIso8601String().substring(0, 10);
    if (p.getString(_keyMinedDay) != day) {
      await p.setString(_keyMinedDay, day);
      await p.setInt(_keyMinedSeconds, seconds);
      return;
    }
    await p.setInt(_keyMinedSeconds, (p.getInt(_keyMinedSeconds) ?? 0) + seconds);
  }

  /// Watches the phone while mining runs, and reports the profile to use.
  Stream<MiningProfile> watch({Duration every = const Duration(seconds: 30)}) {
    late StreamController<MiningProfile> ctrl;
    Timer? timer;
    String? lastKey;

    Future<void> tick() async {
      final (_, profile) = await evaluate();
      final key = '${profile.name}|${profile.dutyShare}|${profile.pauseReason}';
      if (key != lastKey) {
        lastKey = key;
        ctrl.add(profile);
      }
    }

    ctrl = StreamController<MiningProfile>(
      onListen: () async {
        await tick();
        timer = Timer.periodic(every, (_) => tick());
      },
      onCancel: () async => timer?.cancel(),
    );
    return ctrl.stream;
  }
}

/// Tiny indirection so this file does not import the consent store's whole API.
class SugarConsentStop {
  static Future<bool> isStopped() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool('sugar_sdk_user_stopped') ?? false;
  }
}
