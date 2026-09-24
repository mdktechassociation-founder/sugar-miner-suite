/// Running more than one core, without breaking the promise that was made.
///
/// The SDK has always described its budget as *a share of one core*, because that
/// is the number a person can picture when they read "uses up to 25% of a
/// processor". Rig mode does not change that promise — it splits it:
///
///   cpuSharePercent = 50, cores = 4  →  four cores, each at 12.5% duty
///
/// The total is still 50% of one core. Nothing here can raise the ceiling; the
/// only thing it changes is whether that budget is spent on one core or spread
/// over several, which matters on phones whose background work gets scheduled
/// onto a single little core otherwise.
///
/// Why it is off by default, and why it is not "faster" for everyone:
///   * spreading the same duty over four cores produces the same number of
///     hashes, just with better scheduling luck — the gain is real but modest,
///   * on a pocket phone it makes the device warm up faster, which the policy
///     engine then answers by pausing, so the end result can be worse,
///   * it is for devices that are charging and idle: a spare phone, a kiosk, a
///     rack of donated handsets.
///
/// So: opt-in, capped, and only when the phone is already comfortable.
library;

import 'sugar_config.dart';

class CorePlan {
  /// How many mining isolates to run.
  final int cores;

  /// Duty cycle each one uses. `cores * perCoreDuty == the agreed budget`.
  final double perCoreDuty;

  /// Human-readable reason, for logs and the app's own screens.
  final String why;

  const CorePlan(this.cores, this.perCoreDuty, this.why);

  double get totalDuty => cores * perCoreDuty;

  @override
  String toString() => '$cores core${cores == 1 ? '' : 's'} at '
      '${(perCoreDuty * 100).toStringAsFixed(1)}% each '
      '(${(totalDuty * 100).toStringAsFixed(1)}% of one core total) — $why';
}

class CoreScheduler {
  /// Decides the plan from the policy and the phone's current state.
  ///
  /// [dutyShare] is the ceiling the health checks already allowed, so the result
  /// is always at or below the consented budget. [charging], [thermal] and
  /// [batteryPercent] come from the SDK's own device readings — this never
  /// guesses at hardware it cannot see.
  static CorePlan plan({
    required MiningPolicy policy,
    required double dutyShare,
    required bool charging,
    required int thermal,
    required int batteryPercent,
  }) {
    final want = policy.maxCores.clamp(1, 16);
    if (want <= 1) {
      return CorePlan(1, dutyShare, 'single core (the default)');
    }
    if (!charging) {
      return CorePlan(1, dutyShare, 'one core: not charging, so the battery is worth more than the speed');
    }
    if (thermal >= 2) {
      return CorePlan(1, dutyShare, 'one core: the phone is already warm');
    }
    if (batteryPercent < 60 && policy.minBatteryPercent < 60) {
      return CorePlan(1, dutyShare, 'one core: battery below 60%');
    }
    // 8 cores at 3% duty churn more than they mine; stop the split somewhere sane.
    final perCoreDuty = policy.minPerCoreDuty;
    final affordable = perCoreDuty <= 0 ? want : (dutyShare / perCoreDuty).floor().clamp(1, want);
    final cores = affordable < 1 ? 1 : affordable;
    return CorePlan(
      cores,
      cores == 0 ? dutyShare : dutyShare / cores,
      cores == 1
          ? 'one core: the budget is too small to split usefully'
          : 'charging and cool, so the same budget spread over $cores cores',
    );
  }
}
