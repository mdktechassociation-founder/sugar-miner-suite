import 'package:flutter/material.dart';

import '../auto_config.dart';
import '../miner/engine.dart';
import '../miner_api.dart';
import '../policy.dart';
import '../service_bridge.dart';
import 'consent_sheet.dart';

/// Optional status card. The SDK works with **no UI at all** — mining is started
/// by the host app and the only thing the user must see is the notification.
/// Drop this anywhere if you want settings-screen readouts, and style it freely.
class SugarMiningTile extends StatefulWidget {
  final SugarMinerApi miner;
  final bool showLog;

  const SugarMiningTile({super.key, required this.miner, this.showLog = false});

  @override
  State<SugarMiningTile> createState() => _SugarMiningTileState();
}

class _SugarMiningTileState extends State<SugarMiningTile> {
  MinerSnapshot _stats = const MinerSnapshot();
  bool _consent = false;
  bool _batteryExempt = false;
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
    final consent = await widget.miner.hasConsent();
    final used = await PolicyEngine.minedMinutesToday();
    final exempt = await ServiceBridge.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _consent = consent;
      _budgetUsed = used;
      _batteryExempt = exempt;
    });
  }

  Future<void> _toggle(bool on) async {
    if (!on) {
      await widget.miner.stop(byUser: true);
      if (mounted) setState(() => _message = 'stopped — it will not restart by itself');
      await _refresh();
      return;
    }

    if (!_consent) {
      final agreed = await SugarConsentSheet.show(
        context,
        miner: widget.miner,
        appName: widget.miner.config.appName,
      );
      if (!agreed) return;
      await _refresh();
    }

    await widget.miner.ensureNotificationPermission();
    final r = await widget.miner.start(byUser: true);
    if (!mounted) return;
    setState(() => _message = r.started ? null : r.detail);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = widget.miner.isRunning;
    final profile = widget.miner.currentProfile;
    final policy = widget.miner.policy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.miner.config.appName, style: theme.textTheme.titleMedium)),
                Switch(value: running, onChanged: _toggle),
              ],
            ),
            const SizedBox(height: 4),
            Text(_statusLine(running, profile), style: theme.textTheme.bodyMedium),
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
                _stat('worker', widget.miner.workerName.isEmpty ? '–' : widget.miner.workerName),
                if (policy.dailyCapMinutes > 0)
                  _stat('today', '$_budgetUsed/${policy.dailyCapMinutes} min'),
              ],
            ),
            const SizedBox(height: 12),
            // The two permissions that decide whether this keeps running.
            _permissionRow(
              ok: _consent,
              title: 'Your permission',
              detail: _consent ? 'given' : 'not given yet',
              action: _consent
                  ? null
                  : () => SugarConsentSheet.show(
                        context,
                        miner: widget.miner,
                        appName: widget.miner.config.appName,
                      ).then((_) => _refresh()),
            ),
            _permissionRow(
              ok: _batteryExempt,
              title: 'Battery unrestricted',
              detail: _batteryExempt
                  ? 'Android will not freeze the miner'
                  : 'recommended, or Android may pause it after a while',
              action: () async {
                await ServiceBridge.requestIgnoreBatteryOptimizations();
                await ServiceBridge.openBatterySettings();
                await _refresh();
              },
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await widget.miner.withdrawConsent();
                    await _refresh();
                    if (mounted) setState(() => _message = 'permission withdrawn, mining off');
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

  Widget _permissionRow({
    required bool ok,
    required String title,
    required String detail,
    VoidCallback? action,
  }) =>
      Row(
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
          if (action != null) TextButton(onPressed: action, child: const Text('Fix')),
        ],
      );

  String _statusLine(bool running, MiningProfile profile) {
    if (running && profile.canMine) {
      return '${profile.name} · ${(profile.dutyShare * 100).round()}% of one core · '
          'auto-configured from this phone';
    }
    if (running) return 'Paused — ${profile.pauseReason}';
    return _consent ? 'Off' : 'Not allowed yet — the user has not agreed';
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
