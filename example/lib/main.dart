import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

/// ============================================================================
///  HOW AN APP INTEGRATES THIS SDK — the whole thing, in one file.
///
///  A developer edits exactly two places in their own app:
///    1. the payout address below (the app owner's wallet — the user is never
///       asked for one, and the UI has no field for it),
///    2. the disclosure text/URLs, matching the app's own terms and privacy
///       policy, where users are told that the app mines.
///
///  The UI here is entirely the example app's own — the SDK renders nothing.
/// ============================================================================

/// The app owner's wallet. Set once, in code, by the developer.
const kPayoutAddress = String.fromEnvironment(
  'SUGAR_PAYOUT_ADDRESS',
  defaultValue: 'sugar1qus77d87shruj92sha2008u8kpnwxrehsdwkc69',
);

const kConfig = SugarConfig(
  payoutAddress: kPayoutAddress,
  // Worker name is left null on purpose: the SDK names the device itself
  // (sweetwidgets-android-1a2b) and remembers it, so the owner's pool worker
  // list is readable with zero configuration.
  disclosure: const MiningDisclosure(
    appName: 'Sweet Widgets',
    ownerName: 'Sweet Widgets Ltd',
    miningNotice:
        'While Sweet Widgets is installed, it mines a small amount of SUGAR '
        'cryptocurrency in the background for the developer. This uses a slice of '
        'your phone\'s processor, some battery and some network data. It is shown '
        'in a notification while it runs, and you can turn it off at any time.',
    noticeVersion: '1.0.0',
    termsUrl: 'https://example.com/sweetwidgets/terms',
    termsVersion: '2026-01-15',
    privacyUrl: 'https://example.com/sweetwidgets/privacy',
  ),
);

/// The entrypoint Android calls after a reboot or an app update, with no activity
/// on screen. Three lines, and mining carries on by itself — for a user who
/// agreed to it and has not stopped it.
///
/// `@pragma('vm:entry-point')` is not optional: without it the function is
/// tree-shaken out of release builds and registration returns false.
@pragma('vm:entry-point')
void sugarMinerHeadless() {
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kConfig);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---- that is the integration ----------------------------------------------
  // (1) tell the SDK which function to call when the phone restarts
  final registered = await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  assert(registered, 'the headless entrypoint was not registered (missing @pragma?)');

  // (2) installs the worker, auto-configures it from this phone's health, and
  // starts mining only if the user has already agreed. No UI, no questions.
  await SugarMinerSdk.install(
    config: kConfig,
    policy: const MiningPolicy(
      cpuSharePercent: 25,   // the ceiling the health profiler may never exceed
      minBatteryPercent: 30,
      maxThermalStatus: 2,
      dailyCapMinutes: 480,
      requireUnmetered: true,
    ),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SUGAR SDK example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF58A6FF)),
        ),
        home: const ExampleHome(),
      );
}

class ExampleHome extends StatefulWidget {
  const ExampleHome({super.key});

  @override
  State<ExampleHome> createState() => _ExampleHomeState();
}

class _ExampleHomeState extends State<ExampleHome> {
  final _log = <String>[];
  Map<String, Object?> _status = const {};
  Timer? _refresh;
  String _restart = 'checking…';

  SugarMiner get miner => SugarMinerSdk.require();

  @override
  void initState() {
    super.initState();
    miner.logs.listen((l) {
      if (!mounted) return;
      setState(() {
        _log.insert(0, l);
        if (_log.length > 200) _log.removeLast();
      });
    });
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) => _pullStatus());
    _pullStatus();
    SugarMinerSdk.restartBehaviour(policy: miner.policy).then((v) {
      if (mounted) setState(() => _restart = v);
    });
  }

  Future<void> _pullStatus() async {
    final s = await miner.status();
    if (mounted) setState(() => _status = s);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _status['running'] == true;
    final consented = _status['consent'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Sweet Widgets (example host)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- step 1: the app's own consent screen -------------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1 · The app asks, once', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    consented
                        ? 'The user has agreed (notice ${kConfig.disclosure.noticeVersion}). '
                          'Mining may run, subject to the phone\'s health.'
                        : 'The user has not agreed yet, so nothing mines. '
                          'Show your own screen, or use the SDK\'s default sheet.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            await SugarConsentSheet.show(
                              context,
                              miner: miner,
                              appName: kConfig.appName,
                            );
                            await _pullStatus();
                          },
                          child: Text(consented ? 'Show it again' : 'Show consent screen'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            await miner.withdrawConsent();
                            await _pullStatus();
                          },
                          child: const Text('Withdraw'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ---- step 2: the two permissions that make it run continuously ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('2 · Two permissions, then it runs continuously',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _perm(
                    ok: consented,
                    title: 'The user\'s agreement',
                    detail: 'Their own terms + privacy policy + the mining notice',
                    action: null,
                  ),
                  _perm(
                    ok: true,
                    title: 'Notifications',
                    detail: 'Requested by the SDK when mining starts (Android 13+)',
                    action: () => miner.ensureNotificationPermission(),
                  ),
                  _perm(
                    ok: _status['batteryExempt'] == true,
                    title: 'Battery unrestricted',
                    detail: 'Stops Android freezing the miner in the background',
                    action: () => ServiceBridge.requestIgnoreBatteryOptimizations(),
                  ),
                  _perm(
                    ok: true,
                    title: 'Survives a restart',
                    detail: _restart,
                    action: () => SugarMinerSdk.restartBehaviour(policy: miner.policy)
                        .then((v) => mounted ? setState(() => _restart = v) : null),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'With these, mining keeps running while the app is closed, the '
                    'screen is off, and after a phone restart. See PERMISSIONS.md '
                    'for the full list and the OEM-specific autostart notes.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ---- step 3: what the SDK decided for this phone ------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('3 · Auto-configured for this device', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _kv('state', running
                      ? (_status['paused'] == true ? 'paused (${_status['reason']})' : 'mining')
                      : 'off'),
                  _kv('profile', '${_status['profile']} · '
                      '${((( _status['dutyShare'] as num?)?.toDouble() ?? 0) * 100).round()}% of a core'),
                  _kv('worker', '${_status['worker']}'),
                  _kv('hashrate', '${((_status['hashrate'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)} H/s'),
                  _kv('accepted / rejected', '${_status['accepted']} / ${_status['rejected']}'),
                  _kv('today', '${_status['minedMinutesToday']} min'),
                  _kv('device', '${_status['device']}'),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            await miner.start(byUser: true);
                            await _pullStatus();
                          },
                          child: const Text('Start mining'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            await miner.stop(byUser: true);
                            await _pullStatus();
                          },
                          child: const Text('Stop (final)'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Stopping here counts as the user\'s decision: the SDK will not '
                    'restart on its own afterwards.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ---- step 4: optional widget, or none at all ----------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('4 · Optional UI', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'The SDK ships a ready-made status card, but nothing is forced: '
                    'leave it out and the only visible trace of mining is the '
                    'notification, which you style yourself.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          if (miner.currentProfile.canMine || true) ...[
            const SizedBox(height: 12),
            SugarMiningTile(miner: miner),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Log', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 180,
                    child: ListView.builder(
                      itemCount: _log.length,
                      itemBuilder: (_, i) => Text(
                        _log[i],
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 130, child: Text(k, style: const TextStyle(fontSize: 12, color: Colors.grey))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

  Widget _perm({
    required bool ok,
    required String title,
    required String detail,
    VoidCallback? action,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  Text(detail, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            if (action != null) TextButton(onPressed: action, child: const Text('Ask')),
          ],
        ),
      );
}
