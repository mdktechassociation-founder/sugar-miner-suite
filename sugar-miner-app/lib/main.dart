import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'miner_host.dart';
import 'miner/engine.dart';
import 'miner/yespower.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SugarMinerApp());
}

class SugarMinerApp extends StatelessWidget {
  const SugarMinerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SUGAR Miner',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF58A6FF), brightness: Brightness.dark),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _wallet = TextEditingController();
  final _worker = TextEditingController(text: 'phone');
  final _host = TextEditingController(text: 'stratum.poolab.org');
  final _port = TextEditingController(text: '8451');

  final _miner = MinerHost.forThisPlatform();
  final _log = <String>[];
  final _subs = <StreamSubscription>[];

  MinerSnapshot _stats = const MinerSnapshot();
  bool _running = false;
  String _engine = 'loading…';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _probeNativeEngine();
    _bindService();
  }

  Future<void> _loadSettings() async {
    final s = await AppSettings.load();
    if (!mounted) return;
    setState(() {
      _wallet.text = s.wallet;
      _worker.text = s.worker;
      _host.text = s.host;
      _port.text = '${s.port}';
    });
  }

  /// Proves on the device itself that the hashing core is the correct one:
  /// it hashes the SugarChain genesis header and compares against the PoW hash
  /// the coin's source code asserts. Anything else and mining would be pointless.
  Future<void> _probeNativeEngine() async {
    // let the first frame finish: everything below is synchronous C and would
    // otherwise call setState during initState
    await Future<void>.delayed(Duration.zero);
    try {
      final yp = Yespower.load();
      const genesisHeader =
          '0100000000000000000000000000000000000000000000000000000000000000'
          '00000000b050e156acdac2cada87b39ce5f137f5b872901e6b9e1c1d41b09c572ace7776'
          '7073555dffff3f1ff7000000';
      final digest = yp.hashHeader(hexToBytes(genesisHeader));
      final display = digest.reversed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      const expected = '0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb';
      if (!mounted) return;
      setState(() => _engine = display == expected
          ? '✓ ${yp.version}'
          : '✗ WRONG HASH ($display)');
      _append(display == expected
          ? 'self-test passed: this device reproduces the Sugarchain genesis PoW hash'
          : 'SELF-TEST FAILED — do not mine, the native library is wrong');
    } catch (e) {
      if (!mounted) return;
      setState(() => _engine = 'unavailable: $e');
      _append('native library error: $e');
    }
  }

  void _bindService() {
    // The host already drops empty payloads, so there is nothing to null-check
    // here; the events that arrive are the ones with something in them.
    _subs.add(_miner.on('stats').listen((e) {
      if (!mounted) return;
      setState(() => _stats = MinerSnapshot.fromJson(Map<String, dynamic>.from(e)));
    }));
    _subs.add(_miner.on('log').listen((e) {
      _append((e['message'] ?? e).toString());
    }));
    _subs.add(_miner.on('share').listen((e) {
      _append(e['accepted'] == true ? 'share accepted ✓' : 'share rejected: ${e['error']}');
    }));
    _miner.isRunning().then((v) {
      if (mounted) setState(() => _running = v);
    });
  }

  void _append(String m) {
    final t = DateTime.now();
    final stamp = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _log.insert(0, '[$stamp] $m');
      if (_log.length > 300) _log.removeLast();
    });
  }

  Future<void> _start() async {
    final wallet = _wallet.text.trim();
    if (!AppSettings.isValidAddress(wallet)) {
      _append('enter a valid SUGAR payout address (sugar1q…)');
      return;
    }
    await AppSettings(
      wallet: wallet,
      worker: _worker.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 8451,
    ).save();

    // keep the CPU awake while plugged in and mining
    await WakelockPlus.enable();
    await _miner.start();
    if (mounted) setState(() => _running = true);
    _append('miner starting — a notification will stay up while it runs');
  }

  Future<void> _stop() async {
    _miner.invoke('stop');
    await WakelockPlus.disable();
    if (mounted) {
      setState(() {
        _running = false;
        _stats = const MinerSnapshot();
      });
    }
    _append('stopped');
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('SUGAR Miner'),
            Text('engine $_engine', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _wallet,
                    decoration: const InputDecoration(
                      labelText: 'Payout address (yours)',
                      hintText: 'sugar1q…',
                    ),
                    enabled: !_running,
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _worker,
                        decoration: const InputDecoration(labelText: 'Worker'),
                        enabled: !_running,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _port,
                        decoration: const InputDecoration(labelText: 'Port'),
                        keyboardType: TextInputType.number,
                        enabled: !_running,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: 'Pool host'),
                    enabled: !_running,
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _running ? null : _start,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start mining'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _running ? _stop : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'Mining continues with the screen off, as long as the notification stays up. '
                    'Android may still throttle heavy CPU use in deep sleep — keep the phone plugged in.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.25,
            children: [
              _tile('hashrate', '${_stats.hashrate.toStringAsFixed(1)} H/s'),
              _tile('accepted', '${_stats.accepted}'),
              _tile('rejected', '${_stats.rejected}'),
              _tile('difficulty', _stats.difficulty.toStringAsFixed(3)),
              _tile('best share diff', _stats.bestShareDiff.toStringAsExponential(2)),
              _tile('job age', '${_stats.jobAgeSeconds}s'),
              _tile('hashes', _fmt(_stats.hashes)),
              _tile('shares found', '${_stats.sharesFound}'),
              _tile('job', _stats.jobId ?? '–'),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Log', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 220,
                    child: ListView.builder(
                      itemCount: _log.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          _log[i],
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
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

  Widget _tile(String k, String v) => Card(
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(k, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
