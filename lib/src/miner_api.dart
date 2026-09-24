import 'miner/engine.dart';
import 'sugar_config.dart';

/// The surface the widgets need. [SugarMiner] implements it, and it exists as its
/// own file so the widgets never have to import the library that imports them.
abstract class SugarMinerApi {
  bool get isRunning;
  PolicyDecision get lastDecision;
  MiningPolicy get policy;
  SugarConfig get config;

  Stream<MinerSnapshot> get stats;
  Stream<String> get logs;
  Stream<PolicyDecision> get policyChanges;

  Future<MinerStartResult> start();
  Future<void> stop();
  Future<bool> ensureNotificationPermission();
}
