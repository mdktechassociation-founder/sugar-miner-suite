/// Consented background SUGAR mining for Flutter apps.
///
/// Add it to an app, ask the device owner once, and the app can mine
/// yespowerSUGAR for the publisher's address while it is backgrounded — politely:
/// a quarter of one core by default, an always-visible notification, and hard
/// stops for heat, battery, data and a daily time budget.
///
/// ```dart
/// final miner = SugarMiner(config: SugarConfig(payoutAddress: 'sugar1q…'));
///
/// // 1. ask once, in your own UI
/// await SugarConsentSheet.show(context, miner: miner);
///
/// // 2. start / stop whenever you like
/// await miner.start();
/// miner.stats.listen((s) => print('${s.hashrate} H/s'));
/// ```
///
/// What this SDK will never do — by construction, not by convention:
/// it never mines without a recorded consent, it never hides its notification,
/// it has no stealth/silent/hidden option, and it never evades battery or
/// thermal limits. Those are not "not yet implemented" — there is no code path.
library;

import 'dart:async';

import 'consent.dart';
import 'miner/engine.dart';
import 'miner_isolate.dart';
import 'policy.dart';
import 'service_bridge.dart';
import 'sugar_config.dart';

export 'consent.dart';
export 'miner/engine.dart' show MinerSnapshot, ShareFound, hashesPerShare;
export 'policy.dart';
export 'service_bridge.dart';
export 'sugar_config.dart';
export 'widgets/consent_sheet.dart';
export 'widgets/mining_tile.dart';

/// The whole public surface: configure once, then [start] / [stop] / [dispose].
class SugarMiner implements SugarMinerLike {
  @override
  final SugarConfig config;
  @override
  final MiningPolicy policy;

  MinerIsolate? _isolate;
  StreamSubscription<PolicyDecision>? _watchdog;
  Timer? _budgetTicker;
  PolicyDecision _lastDecision = PolicyDecision.ok;
  final List<String> _recentLog = <String>[];

  final StreamController<MinerSnapshot> _stats = StreamController<MinerSnapshot>.broadcast();
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<PolicyDecision> _policyChanges =
      StreamController<PolicyDecision>.broadcast();

  SugarMiner({required this.config, this.policy = const MiningPolicy()});

  /// Live hashrate / share counters from the hashing isolate.
  @override
  Stream<MinerSnapshot> get stats => _stats.stream;

  /// Everything the miner has to say — pool messages, shares, policy stops.
  Stream<String> get logs => _logs.stream;

  /// Emitted when the policy lets mining start or forces it to stop.
  Stream<PolicyDecision> get policyChanges => _policyChanges.stream;

  @override
  bool get isRunning => _isolate != null;
  bool get isPaused => _lastDecision.allowed == false;
  @override
  PolicyDecision get lastDecision => _lastDecision;
  List<String> get recentLog => List.unmodifiable(_recentLog.reversed.take(50));

  /// Asks the OS for notification permission (Android 13+). Without it the
  /// notification cannot be posted, and mining without a visible notification is
  /// exactly the thing this SDK refuses to do.
  @override
  Future<bool> ensureNotificationPermission() async {
    final allowed = await ServiceBridge.requestNotificationPermission();
    if (!allowed) _note('notification permission refused — mining needs it');
    return allowed;
  }

  /// Starts mining if the user agreed and the phone is in a fit state.
  @override
  Future<MinerStartResult> start() async {
    if (_isolate != null) return const MinerStartResult(true, 'already running');

    if (!config.isValid) {
      return const MinerStartResult(false, 'payout address is not a valid SUGAR address');
    }

    // ---- the gate everything hangs on --------------------------------------
    if (!await SugarConsent.isGranted()) {
      _note('refused to start: the user has not agreed to mining');
      return const MinerStartResult(false, 'no consent recorded');
    }

    if (!await ensureNotificationPermission()) {
      return const MinerStartResult(false, 'notification permission is required');
    }

    final decision = await PolicyEngine(policy).evaluate();
    _lastDecision = decision;
    _policyChanges.add(decision);

    await ServiceBridge.startForeground(
      title: 'Mining SUGAR',
      text: decision.allowed
          ? 'Starting the hashing core…'
          : 'Paused — ${decision.reason}',
    );

    if (!decision.allowed) {
      // The notification stays up so the user can see the miner is waiting, but
      // no hashing happens until the phone qualifies.
      _note('not hashing yet: ${decision.reason}');
      _armWatchdog(startWhenAllowed: true);
      return MinerStartResult(false, decision.reason);
    }

    return _spinUp();
  }

  Future<MinerStartResult> _spinUp() async {
    _isolate = await MinerIsolate.spawn(
      config: config,
      policy: policy,
      onLog: _note,
    );
    _isolate!.stats.listen((s) {
      _stats.add(s);
      // one line in the notification, refreshed about every second
      ServiceBridge.updateNotification(
        title: 'Mining SUGAR — ${s.hashrate.toStringAsFixed(0)} H/s',
        text: 'accepted ${s.accepted} · rejected ${s.rejected} · diff '
            '${s.difficulty.toStringAsFixed(2)}',
      ).catchError((_) {});
    });
    _isolate!.logs.listen(_note);
    _isolate!.shares.listen((accepted) => _note(accepted ? 'share accepted ✓' : 'share rejected'));

    _armWatchdog();
    _startBudgetTicker();
    _note('mining started (${policy.cpuSharePercent}% of one core)');
    return const MinerStartResult(true, 'mining');
  }

  /// Stops hashing and takes the notification down.
  @override
  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    _budgetTicker?.cancel();
    _budgetTicker = null;
    await _isolate?.stop();
    _isolate = null;
    await ServiceBridge.stopForeground();
    _note('mining stopped');
  }

  /// Keeps checking the policy; pauses and resumes as the phone changes state.
  void _armWatchdog({bool startWhenAllowed = false}) {
    _watchdog?.cancel();
    _watchdog = PolicyEngine(policy).watch().listen((d) async {
      final changed = d.allowed != _lastDecision.allowed || d.reason != _lastDecision.reason;
      _lastDecision = d;
      if (!changed) return;
      _policyChanges.add(d);
      _note(d.allowed ? 'conditions ok — resuming' : 'paused — ${d.reason}');
      await ServiceBridge.updateNotification(
        title: d.allowed ? 'Mining SUGAR' : 'SUGAR mining paused',
        text: d.allowed ? 'hashing…' : d.reason,
      );
      if (!d.allowed) {
        _isolate?.pause();
      } else if (_isolate != null) {
        _isolate!.resume();
      } else if (startWhenAllowed) {
        await _spinUp();
      }
    });
  }

  /// Counts mining time against the daily budget the user agreed to.
  void _startBudgetTicker() {
    _budgetTicker?.cancel();
    _budgetTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_isolate != null && _lastDecision.allowed) {
        PolicyEngine.addMinedSeconds(60);
      }
    });
  }

  void _note(String line) {
    _recentLog.add(line);
    if (_recentLog.length > 200) _recentLog.removeAt(0);
    if (!_logs.isClosed) _logs.add(line);
  }

  Future<void> dispose() async {
    await stop();
    await _stats.close();
    await _logs.close();
    await _policyChanges.close();
  }
}
