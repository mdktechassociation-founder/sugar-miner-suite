import 'package:flutter/material.dart';

import '../consent.dart';
import '../miner/engine.dart';
import '../miner_api.dart';
import '../policy.dart';
import '../service_bridge.dart';
import '../sugar_config.dart';
import 'consent_sheet.dart';

/// A ready-made status card: what the miner is doing, and the switch to stop it.
/// Drop it anywhere in the host app's settings screen.
class SugarMiningTile extends StatefulWidget {
  final SugarMinerApi miner;
  const SugarMiningTile({super.key, required this.miner});

  @override
  State<SugarMiningTile> createState() => _SugarMiningTileState();
}

class _SugarMiningTileState extends State<SugarMiningTile> {
  MinerSnapshot _stats = const MinerSnapshot();
  bool _consent = false;
  int _budgetUsed = 0;
  String? _message;

  @override
  void initState() {
    super.initState();
    _refresh();
    widget.miner.stats.listen((s) {
      if (mounted) setState(() => _stats = s);
    });
  }

  Future<void> _refresh() async {
    final consent = await SugarConsent.isGranted();
    final used = await PolicyEngine.minedMinutesToday();
    if (!mounted) return;
    setState(() {
      _consent = consent;
      _budgetUsed = used;
    });
  }

  Future<void> _toggle(bool on) async {
    if (!on) {
      await widget.miner.stop();
      if (mounted) setState(() => _message = 'stopped');
      await _refresh();
      return;
    }

    if (!_consent) {
      final agreed = await SugarConsentSheet.show(context, appName: 'This app');
      if (!agreed) return;
      await _refresh();
    }

    await widget.miner.ensureNotificationPermission();
    final r = await widget.miner.start();
    if (!mounted) return;
    setState(() => _message = r.started ? null : r.detail);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = widget.miner.isRunning;
    final decision = widget.miner.lastDecision;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('SUGAR mining', style: theme.textTheme.titleMedium),
                ),
                Switch(
                  value: running,
                  onChanged: _toggle,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _statusLine(running, decision),
              style: theme.textTheme.bodyMedium,
            ),
            if (_message != null) ...[
              const SizedBox(height: 6),
              Text(_message!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _stat('hashrate', '${_stats.hashrate.toStringAsFixed(0)} H/s'),
                _stat('accepted', '${_stats.accepted}'),
                _stat('best share', _stats.bestShareDiff == 0
                    ? '–'
                    : _stats.bestShareDiff.toStringAsExponential(2)),
                _stat('difficulty', _stats.difficulty.toStringAsFixed(3)),
                if (widget.miner.policy.dailyCapMinutes > 0)
                  _stat('today', '$_budgetUsed/${widget.miner.policy.dailyCapMinutes} min'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: ServiceBridge.openBatterySettings,
                  icon: const Icon(Icons.battery_saver, size: 18),
                  label: const Text('Battery settings'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await SugarConsent.revoke();
                    await widget.miner.stop();
                    await _refresh();
                    if (mounted) setState(() => _message = 'consent withdrawn, mining off');
                  },
                  child: const Text('Withdraw permission'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _statusLine(bool running, PolicyDecision d) {
    if (running && d.allowed) {
      return 'Mining in the background, ${widget.miner.policy.cpuSharePercent}% of a core';
    }
    if (running) return 'Paused — ${d.reason}';
    return _consent ? 'Off' : 'Not allowed yet — no permission from you';
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      );
}
