import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'consent.dart';
import 'service_bridge.dart';
import 'sugar_config.dart';

/// Applies [MiningPolicy] to the actual phone, and keeps a daily time budget.
class PolicyEngine {
  final MiningPolicy policy;
  PolicyEngine(this.policy);

  static const _keyMinedDay = 'sugar_sdk_mined_day';
  static const _keyMinedSeconds = 'sugar_sdk_mined_seconds';

  /// Ask Android what the device is doing right now.
  Future<DeviceState> deviceState() async {
    try {
      return DeviceState.fromMap(await ServiceBridge.deviceState());
    } catch (_) {
      return DeviceState.unknown;
    }
  }

  /// Decide whether mining may run, given the device and today's usage.
  Future<PolicyDecision> evaluate({DeviceState? state}) async {
    final s = state ?? await deviceState();

    if (policy.requireCharging && !s.charging) {
      return const PolicyDecision(false, 'waiting for the charger');
    }
    if (!s.charging && s.batteryPercent < policy.minBatteryPercent) {
      return PolicyDecision(
          false, 'battery ${s.batteryPercent}% is below ${policy.minBatteryPercent}%');
    }
    if (policy.requireUnmetered && !s.onWifi) {
      return const PolicyDecision(false, 'waiting for wifi');
    }
    if (s.thermalStatus > policy.maxThermalStatus) {
      return PolicyDecision(
          false, 'phone is too warm (${s.thermalLabel}) — cooling down');
    }
    if (s.powerSaveMode && !s.charging) {
      return const PolicyDecision(false, 'battery saver is on');
    }
    if (policy.dailyCapMinutes > 0) {
      final used = await minedMinutesToday();
      if (used >= policy.dailyCapMinutes) {
        return PolicyDecision(
            false, "today's ${policy.dailyCapMinutes} minute limit is used up");
      }
    }
    return PolicyDecision.ok;
  }

  /// Minutes mined so far today (the budget resets at midnight local time).
  static Future<int> minedMinutesToday() async {
    final p = await SharedPreferences.getInstance();
    final day = DateTime.now().toIso8601String().substring(0, 10);
    if (p.getString(_keyMinedDay) != day) return 0;
    return (p.getInt(_keyMinedSeconds) ?? 0) ~/ 60;
  }

  /// Called by the miner every minute while it runs, so the budget is honest.
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

  /// Watches the policy while mining runs and pauses/resumes as needed.
  /// Returns a stream of decisions; the first one is emitted immediately.
  Stream<PolicyDecision> watch({Duration every = const Duration(seconds: 30)}) {
    late StreamController<PolicyDecision> ctrl;
    Timer? timer;
    var last = <String>[];

    Future<void> tick() async {
      final d = await evaluate();
      if (last.isEmpty || last.last != '${d.allowed}|${d.reason}') {
        last = [..last, '${d.allowed}|${d.reason}'];
        ctrl.add(d);
      }
    }

    ctrl = StreamController<PolicyDecision>(
      onListen: () async {
        await tick();
        timer = Timer.periodic(every, (_) => tick());
      },
      onCancel: () async => timer?.cancel(),
    );
    return ctrl.stream;
  }
}

/// A tiny helper the host app can use to gate its own UI on consent.
Future<bool> miningConsentGiven() => SugarConsent.isGranted();
