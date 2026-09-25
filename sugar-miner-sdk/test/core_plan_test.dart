// The one promise rig mode must never break: spreading the budget over more
// cores cannot make the total bigger. Every test here is a way of trying to
// break that, so the whole file doubles as the argument for why the feature is
// safe to hand to someone else's app.
import 'package:flutter_test/flutter_test.dart';
import 'package:sugar_miner_sdk/src/core_plan.dart';
import 'package:sugar_miner_sdk/src/sugar_config.dart';

void main() {
  const base = MiningPolicy();

  group('the budget is a ceiling, not a starting point', () {
    test('total duty never exceeds the consented share, for any combination', () {
      for (var share = 1; share <= 100; share++) {
        for (final cores in const [1, 2, 4, 6, 8, 12, 16]) {
          for (final charging in [true, false]) {
            for (final thermal in [0, 1, 2, 3]) {
              for (final battery in [5, 50, 79, 100]) {
                final policy = MiningPolicy(cpuSharePercent: share, maxCores: cores);
                final plan = CoreScheduler.plan(
                  policy: policy,
                  dutyShare: policy.ceilingDutyShare,
                  charging: charging,
                  thermal: thermal,
                  batteryPercent: battery,
                );

                expect(plan.cores, greaterThanOrEqualTo(1));
                expect(
                  plan.totalDuty,
                  lessThanOrEqualTo(policy.ceilingDutyShare + 1e-9),
                  reason: 'share=$share cores=$cores charging=$charging '
                      'thermal=$thermal battery=$battery gave $plan',
                );
                expect(plan.perCoreDuty, greaterThanOrEqualTo(0));
              }
            }
          }
        }
      }
    });

    test('a zero budget stays zero, however many cores are offered', () {
      for (final cores in const [1, 4, 16]) {
        final plan = CoreScheduler.plan(
          policy: MiningPolicy(cpuSharePercent: 1, maxCores: cores),
          dutyShare: 0,
          charging: true,
          thermal: 0,
          batteryPercent: 100,
        );
        expect(plan.totalDuty, 0);
      }
    });
  });

  group('opt-in: nothing changes unless the developer asks for it', () {
    test('the default policy is one core, always', () {
      expect(base.maxCores, 1);
      final plan = CoreScheduler.plan(
        policy: base,
        dutyShare: base.ceilingDutyShare,
        charging: true,
        thermal: 0,
        batteryPercent: 100,
      );
      expect(plan.cores, 1);
      expect(plan.perCoreDuty, base.ceilingDutyShare,
          reason: 'a single core runs the full agreed budget');
    });
  });

  group('the phone gets a veto', () {
    const policy = MiningPolicy(cpuSharePercent: 80, maxCores: 8);

    test('not charging means one core', () {
      final plan = CoreScheduler.plan(
        policy: policy,
        dutyShare: policy.ceilingDutyShare,
        charging: false,
        thermal: 0,
        batteryPercent: 100,
      );
      expect(plan.cores, 1);
      expect(plan.why, contains('not charging'));
    });

    test('a warm phone means one core', () {
      for (final t in const [2, 3, 4]) {
        final plan = CoreScheduler.plan(
          policy: policy,
          dutyShare: policy.ceilingDutyShare,
          charging: true,
          thermal: t,
          batteryPercent: 100,
        );
        expect(plan.cores, 1, reason: 'thermal=$t');
      }
    });

    test('a phone below 60% means one core', () {
      for (final b in const [0, 20, 59]) {
        final plan = CoreScheduler.plan(
          policy: policy,
          dutyShare: policy.ceilingDutyShare,
          charging: true,
          thermal: 0,
          batteryPercent: b,
        );
        expect(plan.cores, 1, reason: 'battery=$b');
      }
    });

    test('charging, cool and above 60% is the only way to a rig', () {
      final plan = CoreScheduler.plan(
        policy: policy,
        dutyShare: policy.ceilingDutyShare,
        charging: true,
        thermal: 1,
        batteryPercent: 60,
      );
      expect(plan.cores, greaterThan(1));
    });

    test('unknown device readings are not treated as permission', () {
      // Android reports nothing useful before the first battery broadcast:
      // percent comes back as -1. That must read as "no", not as "plenty".
      final plan = CoreScheduler.plan(
        policy: policy,
        dutyShare: policy.ceilingDutyShare,
        charging: true,
        thermal: 0,
        batteryPercent: -1,
      );
      expect(plan.cores, 1);
    });
  });

  group('the split itself', () {
    test('50% over four cores is four cores at 12.5%', () {
      final plan = CoreScheduler.plan(
        policy: const MiningPolicy(cpuSharePercent: 50, maxCores: 4),
        dutyShare: 0.5,
        charging: true,
        thermal: 0,
        batteryPercent: 90,
      );
      expect(plan.cores, 4);
      expect(plan.perCoreDuty, closeTo(0.125, 1e-9));
      expect(plan.totalDuty, closeTo(0.5, 1e-9));
    });

    test('a core never gets less than the useful minimum', () {
      const policy = MiningPolicy(cpuSharePercent: 50, maxCores: 16, minPerCoreDuty: 0.10);
      final plan = CoreScheduler.plan(
        policy: policy,
        dutyShare: 0.5,
        charging: true,
        thermal: 0,
        batteryPercent: 90,
      );
      expect(plan.perCoreDuty, greaterThanOrEqualTo(policy.minPerCoreDuty - 1e-9));
      expect(plan.cores, lessThanOrEqualTo(5));
    });

    test('a budget too small to split stays on one core', () {
      final plan = CoreScheduler.plan(
        policy: const MiningPolicy(cpuSharePercent: 1, maxCores: 8, minPerCoreDuty: 0.02),
        dutyShare: 0.01,
        charging: true,
        thermal: 0,
        batteryPercent: 90,
      );
      expect(plan.cores, 1);
      expect(plan.perCoreDuty, closeTo(0.01, 1e-9));
    });

    test('the plan explains itself in plain words', () {
      final rig = CoreScheduler.plan(
        policy: const MiningPolicy(cpuSharePercent: 40, maxCores: 4),
        dutyShare: 0.4,
        charging: true,
        thermal: 0,
        batteryPercent: 100,
      );
      expect(rig.toString(), contains('4 cores at 10.0% each'));
      expect(rig.toString(), contains('40.0% of one core total'));
    });
  });
}
