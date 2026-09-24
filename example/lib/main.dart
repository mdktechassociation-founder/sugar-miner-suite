import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

/// A host app's screen. In a real app the payout address is *your* address,
/// compiled in — the user is never asked for a wallet, they are only asked for
/// permission. This example lets you paste one so you can test with your own.
class ExampleHome extends StatefulWidget {
  const ExampleHome({super.key});

  @override
  State<ExampleHome> createState() => _ExampleHomeState();
}

class _ExampleHomeState extends State<ExampleHome> {
  static const _keyAddress = 'example_payout_address';

  final _address = TextEditingController();
  final _worker = TextEditingController(text: 'example-app');
  final _log = <String>[];

  SugarMiner? _miner;
  bool _consent = false;
  int _budget = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _address.text = p.getString(_keyAddress) ?? '';
    });
    await _rebuildMiner();
    _refreshConsent();
  }

  Future<void> _rebuildMiner() async {
    await _miner?.dispose();
    final miner = SugarMiner(
      config: SugarConfig(
        payoutAddress: _address.text.trim(),
        worker: _worker.text.trim(),
      ),
      // Deliberately the polite defaults: a quarter of one core, a hard stop for
      // heat and low battery, and an 8-hour daily ceiling.
      policy: const MiningPolicy(
        cpuSharePercent: 25,
        minBatteryPercent: 30,
        maxThermalStatus: 2,
        dailyCapMinutes: 480,
      ),
    );
    miner.logs.listen((l) => _note(l));
    miner.policyChanges.listen((d) => _note(d.allowed ? 'policy: running' : 'policy: ${d.reason}'));
    if (!mounted) return;
    setState(() => _miner = miner);
  }

  Future<void> _refreshConsent() async {
    final ok = await SugarConsent.isGranted();
    final used = await PolicyEngine.minedMinutesToday();
    if (!mounted) return;
    setState(() {
      _consent = ok;
      _budget = used;
    });
  }

  void _note(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 200) _log.removeLast();
    });
  }

  @override
  void dispose() {
    _miner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final miner = _miner;
    return Scaffold(
      appBar: AppBar(title: const Text('SUGAR SDK example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('1. Configure', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: 'Payout address (the publisher\'s own)',
                      hintText: 'sugar1q…',
                    ),
                    onSubmitted: (_) async {
                      final p = await SharedPreferences.getInstance();
                      await p.setString(_keyAddress, _address.text.trim());
                      await _rebuildMiner();
                      await _refreshConsent();
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final p = await SharedPreferences.getInstance();
                            await p.setString(_keyAddress, _address.text.trim());
                            await _rebuildMiner();
                            await _refreshConsent();
                          },
                          child: const Text('Apply address'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: miner == null
                              ? null
                              : () async {
                                  final agreed = await SugarConsentSheet.show(
                                    context,
                                    miner: miner,
                                    appName: 'SUGAR SDK example',
                                  );
                                  await _refreshConsent();
                                  _note(agreed ? 'consent granted' : 'permission declined');
                                },
                          child: Text(_consent ? 'Permission given ✓' : '2. Ask permission'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A real app asks the user for consent once, at first run. '
                    'Consent is remembered, and it is required before any mining happens.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (miner != null) SugarMiningTile(miner: miner),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Today: $_budget of ${miner?.policy.dailyCapMinutes ?? 0} minutes used',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'The daily budget is stored on the device and counted by the SDK, '
                    'so the miner cannot quietly exceed what the user agreed to.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
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
                    height: 200,
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
}
