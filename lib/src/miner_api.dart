import 'auto_config.dart';
import 'miner/engine.dart';
import 'sugar_config.dart';

/// The surface the widgets and the host app need. [SugarMiner] implements it,
/// and it lives in its own file so the widgets never import the library that
/// imports them.
abstract class SugarMinerApi {
  SugarConfig get config;
  MiningPolicy get policy;

  bool get isRunning;
  bool get isPaused;
  PolicyDecision get lastDecision;

  /// What the health checks chose right now: duty cycle, batch size, or why
  /// mining is stopped.
  MiningProfile get currentProfile;

  /// The pool worker name this device registered (auto-generated, remembered).
  String get workerName;

  Stream<MinerSnapshot> get stats;
  Stream<String> get logs;
  Stream<PolicyDecision> get policyChanges;
  Stream<MiningProfile> get profiles;

  Future<MinerStartResult> start({bool byUser = false});
  Future<void> stop({bool byUser = false});
  Future<bool> ensureNotificationPermission();

  Future<bool> hasConsent();
  Future<void> recordConsent();
  Future<void> withdrawConsent();

  /// Everything the host app may want to show, in one call — including the
  /// device line the health checks produced.
  Future<Map<String, Object?>> status();
}
