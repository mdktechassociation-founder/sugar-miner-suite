/// Consented background SUGAR mining for Flutter apps.
///
/// The SDK is the worker; the app is the host. A developer does three things:
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await SugarMinerSdk.install(
///     config: SugarConfig(
///       payoutAddress: 'sugar1q…the owner\'s address…',   // set here, never asked of the user
///       disclosure: MiningDisclosure(...),                // the app's terms + privacy policy + one plain sentence
///     ),
///   );
///   runApp(const MyApp());
/// }
/// ```
///
/// That is the whole integration. Everything else — worker name, pool choice,
/// duty cycle, batch size — is configured from the phone's own health checks, and
/// the app's UI is untouched unless the developer wants a widget.
///
/// What this SDK will never do, by construction rather than by convention:
/// it never mines without a recorded consent, it never hides its notification,
/// it has no stealth/silent/hidden option, and it never evades the battery or
/// thermal limits. Those are not "not implemented yet" — there is no code path.
library;

import 'dart:async';

import 'src/auto_config.dart';
import 'src/consent.dart';
import 'src/headless.dart' as headless;
import 'src/miner/engine.dart';
import 'src/miner_isolate.dart';
import 'src/miner_api.dart';
import 'src/notification_style.dart';
import 'src/pool_endpoints.dart';
import 'src/policy.dart';
import 'src/service_bridge.dart';
import 'src/sugar_config.dart';

export 'src/auto_config.dart' show AutoConfigurator, DeviceHealth, MiningProfile, WorkerIdentity;
export 'src/consent.dart';
export 'src/headless.dart' show HeadlessEntrypoint;
export 'src/disclosure.dart';
export 'src/miner/engine.dart' show MinerSnapshot, ShareFound, hashesPerShare;
export 'src/miner_api.dart';
export 'src/notification_style.dart';
export 'src/policy.dart' show PolicyEngine;
export 'src/pool_endpoints.dart' show PoolEndpoint, PoolEndpoints;
export 'src/service_bridge.dart';
export 'src/sugar_config.dart';
export 'src/widgets/consent_sheet.dart';
export 'src/widgets/mining_tile.dart';

/// The whole public surface: install once, then [start] / [stop] / [dispose].
class SugarMiner implements SugarMinerApi {
  @override
  final SugarConfig config;
  @override
  final MiningPolicy policy;

  MinerIsolate? _isolate;
  StreamSubscription<MiningProfile>? _watchdog;
  Timer? _budgetTicker;
  MiningProfile _profile = MiningProfile.paused;
  PolicyDecision _lastDecision = PolicyDecision.ok;
  String _workerName = '';
  bool _stoppedByUser = false;
  final List<String> _recentLog = <String>[];

  final StreamController<MinerSnapshot> _stats = StreamController<MinerSnapshot>.broadcast();
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<PolicyDecision> _policyChanges = StreamController<PolicyDecision>.broadcast();
  final StreamController<MiningProfile> _profiles = StreamController<MiningProfile>.broadcast();

  SugarMiner({required this.config, this.policy = const MiningPolicy()});

  @override
  Stream<MinerSnapshot> get stats => _stats.stream;
  @override
  Stream<String> get logs => _logs.stream;
  @override
  Stream<PolicyDecision> get policyChanges => _policyChanges.stream;

  /// The auto-configurator's current setting, whenever it changes.
  @override
  Stream<MiningProfile> get profiles => _profiles.stream;

  MinerSnapshot _lastStats = const MinerSnapshot();

  /// Live numbers the host app can render if it wants to.
  MinerSnapshot get snapshot => _lastStats;

  @override
  bool get isRunning => _isolate != null;
  @override
  bool get isPaused => !_lastDecision.allowed;
  @override
  PolicyDecision get lastDecision => _lastDecision;

  /// The profile the health checks chose: duty cycle, batch size, and why.
  @override
  MiningProfile get currentProfile => _profile;

  /// The worker name this device registered with the pool.
  @override
  String get workerName => _workerName;

  /// True when the user themselves stopped mining — the SDK will not restart it
  /// on its own after that.
  bool get wasStoppedByUser => _stoppedByUser;

  List<String> get recentLog => List.unmodifiable(_recentLog.reversed.take(50));

  // -------------------------------------------------------------- consent

  @override
  Future<bool> hasConsent() => SugarConsent.isGranted(config.disclosure.consentVersion);

  /// Records the user's "yes" — call this after showing them
  /// [SugarConsentSheet] (or your own screen built from [config.disclosure]).
  @override
  Future<void> recordConsent() async {
    await SugarConsent.grant(config.disclosure.consentVersion);
    _stoppedByUser = false;
    _note('consent recorded (notice ${config.disclosure.noticeVersion})');
  }

  /// The user declined, or changed their mind later.
  @override
  Future<void> withdrawConsent() async {
    await SugarConsent.revoke();
    _stoppedByUser = true;
    await stop(byUser: true);
    _note('consent withdrawn — mining will not restart');
  }

  // --------------------------------------------------------------- start

  /// Starts mining if the user agreed and the phone is in a fit state.
  @override
  Future<MinerStartResult> start({bool byUser = false}) async {
    if (_isolate != null) return const MinerStartResult(true, 'already running');

    if (!config.isValid) {
      return const MinerStartResult(
          false, 'config is incomplete: a valid payout address and a complete disclosure are required');
    }

    // ---- the gate everything hangs on --------------------------------------
    if (!await hasConsent()) {
      _note('refused to start: the user has not agreed to the disclosure');
      return const MinerStartResult(false, 'no consent recorded');
    }

    // ---- permission 1: the notification ------------------------------------
    if (!await ensureNotificationPermission()) {
      return const MinerStartResult(false, 'notification permission is required');
    }

    // ---- the health checks decide how hard to work -------------------------
    final engine = PolicyEngine(policy);
    final (decision, profile) = await engine.evaluate();
    _lastDecision = decision;
    _profile = profile;
    _policyChanges.add(decision);
    _profiles.add(profile);
    _note('health: ${await engine.health()}');
    _note('profile: $profile');

    await _showNotification(decision.allowed ? 'starting…' : profile.pauseReason ?? 'paused');

    if (!decision.allowed) {
      // The notification stays up so the user sees the miner waiting, but no
      // hashing happens until the phone qualifies.
      _armWatchdog(engine, startWhenAllowed: true);
      return MinerStartResult(false, profile.pauseReason ?? 'paused');
    }

    return _spinUp(profile.dutyShare, profile.batch);
  }

  Future<MinerStartResult> _spinUp(double duty, int batch) async {
    _workerName = await WorkerIdentity.resolve(
      appSlug: config.appName,
      configured: config.workerName,
    );
    _isolate = await MinerIsolate.spawn(
      config: config,
      policy: policy,
      workerName: _workerName,
      onLog: _note,
    );
    _isolate!.applyProfile(duty, batch);
    _isolate!.stats.listen((s) {
      _lastStats = s;
      _stats.add(s);
      _showNotification(null, hashrate: s);
    });
    _isolate!.logs.listen(_note);
    _isolate!.shares.listen((accepted) => _note(accepted ? 'share accepted ✓' : 'share rejected'));

    _armWatchdog(PolicyEngine(policy));
    _startBudgetTicker();
    _note('mining as worker "$_workerName" (${(duty * 100).round()}% of one core)');
    return const MinerStartResult(true, 'mining');
  }

  /// Stops hashing and takes the notification down.
  @override
  Future<void> stop({bool byUser = false}) async {
    if (byUser) {
      await SugarConsent.markStoppedByUser();
      _stoppedByUser = true;
    }
    _watchdog?.cancel();
    _watchdog = null;
    _budgetTicker?.cancel();
    _budgetTicker = null;
    await _isolate?.stop();
    _isolate = null;
    await ServiceBridge.stopForeground();
    _note('mining stopped');
  }

  /// The health checks keep running: pause, resume or retune on their verdict.
  void _armWatchdog(PolicyEngine engine, {bool startWhenAllowed = false}) {
    _watchdog?.cancel();
    _watchdog = engine.watch().listen((profile) async {
      final wasMining = _profile.canMine;
      _profile = profile;
      _profiles.add(profile);
      final decision = profile.canMine
          ? PolicyDecision.ok
          : PolicyDecision(false, profile.pauseReason ?? 'paused');
      final changed = decision.allowed != _lastDecision.allowed || !profile.canMine;
      _lastDecision = decision;
      if (changed) {
        _policyChanges.add(decision);
        _note(profile.canMine ? 'resuming — ${profile.name}' : 'paused — ${profile.pauseReason}');
      }

      if (!profile.canMine) {
        // keep the isolate but stop hashing: cheaper to resume, and the session
        // on the pool stays open
        await _isolate?.stop();
        _isolate = null;
        await _showNotification('paused');
      } else if (_isolate != null) {
        _isolate!.applyProfile(profile.dutyShare, profile.batch);
        await _showNotification(null);
      } else if (startWhenAllowed || wasMining) {
        await _spinUp(profile.dutyShare, profile.batch);
      }
    });
  }

  void _startBudgetTicker() {
    _budgetTicker?.cancel();
    _budgetTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_isolate != null && _lastDecision.allowed) {
        PolicyEngine.addMinedSeconds(60);
      }
    });
  }

  // -------------------------------------------------------- the notification

  /// Asks for notification permission (Android 13+). Without it the miner cannot
  /// run in the background at all, and this SDK will not mine without it.
  @override
  Future<bool> ensureNotificationPermission() async {
    final allowed = await ServiceBridge.requestNotificationPermission();
    if (!allowed) _note('notification permission refused — mining needs it');
    return allowed;
  }

  /// The notification's words are the developer's, via [NotificationStyle].
  /// It is never hidden, never dismissible and always says it is mining.
  Future<void> _showNotification(String? state, {MinerSnapshot? hashrate}) async {
    final s = hashrate ?? _lastStats;
    final values = NotificationValues.build(
      app: config.appName,
      worker: _workerName.isEmpty ? '—' : _workerName,
      pool: (config.endpoints == null || config.endpoints!.isEmpty)
          ? PoolEndpoints.pooLab.toString()
          : config.endpoints!.first.toString(),
      address: config.payoutAddress,
      hashrate: s.hashrate,
      accepted: s.accepted,
      rejected: s.rejected,
      difficulty: s.difficulty,
      paused: !(_lastDecision.allowed),
      pauseReason: state ?? _lastDecision.reason,
      minedMinutesToday: await PolicyEngine.minedMinutesToday(),
    );
    final title = config.notification.title(values);
    final body = config.notification.body(values);

    if (_isolate == null) {
      await ServiceBridge.startForeground(
        title: title,
        text: body,
        iconName: config.notification.iconName,
        colorArgb: config.notification.colorArgb,
      );
    } else {
      await ServiceBridge.updateNotification(title: title, text: body);
    }
  }

  // -------------------------------------------------------------- plumbing

  void _note(String line) {
    _recentLog.add(line);
    if (_recentLog.length > 200) _recentLog.removeAt(0);
    if (!_logs.isClosed) _logs.add(line);
  }

  /// Everything the host app may want to know, refreshed from one call.
  @override
  Future<Map<String, Object?>> status() async {
    final h = await PolicyEngine(policy).health();
    return {
      'running': isRunning,
      'paused': isPaused,
      'reason': _lastDecision.reason,
      'profile': _profile.name,
      'dutyShare': _profile.dutyShare,
      'worker': _workerName,
      'hashrate': _lastStats.hashrate,
      'accepted': _lastStats.accepted,
      'rejected': _lastStats.rejected,
      'minedMinutesToday': await PolicyEngine.minedMinutesToday(),
      'consent': await hasConsent(),
      'stoppedByUser': _stoppedByUser,
      'batteryExempt': h.raw.ignoringBatteryOptimizations,
      'charging': h.raw.charging,
      'batteryPercent': h.raw.batteryPercent,
      'thermal': h.raw.thermalLabel,
      'device': h.toString(),
    };
  }

  Future<void> dispose() async {
    await stop();
    await _stats.close();
    await _logs.close();
    await _policyChanges.close();
    await _profiles.close();
  }
}

/// Installs the SDK. One call in `main()`, and the app is a mining host.
class SugarMinerSdk {
  static SugarMiner? _instance;

  /// Registers the app's headless entrypoint, which is what lets mining resume
  /// after a phone restart. Call it in `main()`, before [install]:
  ///
  /// ```dart
  /// @pragma('vm:entry-point')
  /// void sugarMinerHeadless() {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   SugarMinerSdk.install(config: kConfig);          // same config, no UI
  /// }
  ///
  /// SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  /// ```
  ///
  /// Returns false when the function was not annotated `@pragma('vm:entry-point')`
  /// (it is tree-shaken out of release builds). In that case mining simply does
  /// not resume on its own — the SDK never pretends otherwise.
  static Future<bool> registerHeadlessEntrypoint(Function entrypoint) =>
      headless.HeadlessEntrypoint.register(entrypoint);

  /// An honest one-liner for the app's own UI: what happens to mining when the
  /// app is closed or the phone is restarted.
  static Future<String> restartBehaviour({MiningPolicy policy = const MiningPolicy()}) =>
      headless.restartBehaviour(policy: policy);

  /// The miner this app installed, if any.
  static SugarMiner? get instance => _instance;

  /// Convenience for apps that do not want to keep the object around.
  static SugarMiner require() {
    final m = _instance;
    if (m == null) {
      throw StateError('SugarMinerSdk.install() was not called in main()');
    }
    return m;
  }

  /// Sets up the miner:
  ///  * resolves the device's worker name (once, then remembered),
  ///  * starts mining if the user already consented and the phone is happy,
  ///  * and if [MiningPolicy.resumeWhenAppOpens] is on, resumes after a restart.
  ///
  /// It never shows UI and never asks the user anything: consent is the host
  /// app's screen, built from [SugarConfig.disclosure].
  static Future<SugarMiner> install({
    required SugarConfig config,
    MiningPolicy policy = const MiningPolicy(),
    bool autoStart = true,
  }) async {
    final miner = SugarMiner(config: config, policy: policy);
    _instance = miner;
    miner._stoppedByUser = await SugarConsent.wasStoppedByUser();

    if (autoStart && policy.resumeWhenAppOpens && !miner._stoppedByUser) {
      final consented = await miner.hasConsent();
      if (consented) {
        // health checks decide whether this actually hashes right now
        await miner.start();
      } else {
        miner._note('waiting for the user to accept the mining disclosure');
      }
    }
    return miner;
  }
}
