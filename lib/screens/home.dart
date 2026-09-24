/// The main screen: what this device has earned, what it is doing right now, and
/// one button to stop it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

import '../app_config.dart';
import '../services/pool_api.dart';
import '../theme.dart';

/// The pool pays out when the balance reaches its own threshold. The app does not
/// set that number — it cannot, it is the pool's policy — so it is shown as an
/// estimate with the source named, and the exact figure is whatever the pool says
/// on its own site when the moment comes.
const double kPoolPayoutThreshold = 1.0;

class HomeScreen extends StatefulWidget {
  final String address;
  final VoidCallback onOpenWallet;
  const HomeScreen({super.key, required this.address, required this.onOpenWallet});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _tick;
  StreamSubscription? _statsSub;
  StreamSubscription? _decisionsSub;
  PoolAccount? _account;
  bool _loadingAccount = false;

  /// Everything about the local miner comes from one place: the SDK's own
  /// `status()` map. The app never keeps a second copy of the truth it could
  /// disagree with the engine about.
  Map<String, Object?> _status = const {};
  MinerSnapshot _stats = const MinerSnapshot();
  final List<String> _recent = [];
  String _restartNote = '';
  bool _busy = false;

  bool get _running => _status['running'] == true;
  String? get _pauseReason {
    final r = _status['reason'];
    return (r == null || r == 'ok') ? null : '$r';
  }

  @override
  void initState() {
    super.initState();
    final miner = SugarMinerSdk.instance;
    _statsSub = miner?.stats.listen((snapshot) {
      if (mounted) setState(() => _stats = snapshot);
    });
    _decisionsSub = miner?.policyChanges.listen((d) {
      if (mounted) {
        setState(() {
          _recent.insert(0, d.allowed ? 'resumed — ${d.reason}' : 'paused — ${d.reason}');
          if (_recent.length > 4) _recent.removeLast();
        });
      }
    });
    _refreshLocal();
    _refreshPool();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      _refreshLocal();
      if (mounted && !_loadingAccount) _refreshPool();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _statsSub?.cancel();
    _decisionsSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final miner = SugarMinerSdk.instance;
    if (miner == null) return;
    final status = await miner.status();
    final note = await SugarMinerSdk.restartBehaviour(policy: AppConfig.policy);
    if (!mounted) return;
    setState(() {
      _status = status;
      _restartNote = note;
    });
  }

  Future<void> _refreshPool() async {
    setState(() => _loadingAccount = true);
    final account = await PoolApi.fetch(widget.address);
    if (!mounted) return;
    setState(() {
      _account = account;
      _loadingAccount = false;
    });
  }

  Future<void> _toggle() async {
    final miner = SugarMinerSdk.instance;
    if (miner == null) return;
    setState(() => _busy = true);
    if (_running) {
      await miner.stop(byUser: true);
      if (mounted) setState(() => _recent.insert(0, 'stopped by you'));
    } else {
      // Starting again after a stop is always the user's own act: clearing the
      // flag here is this button, and nothing else in the app does it.
      await SugarConsent.clearUserStopped();
      final result = await miner.start();
      if (mounted) {
        setState(() => _recent.insert(0,
            result.started ? 'started' : 'not started — ${result.detail}'));
      }
    }
    await _refreshLocal();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final perDay = account?.sugarPerDay;
    final payoutIn = account?.timeToPayout(kPoolPayoutThreshold);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SUGAR Wallet'),
        actions: [
          IconButton(
            tooltip: 'Wallet & backup',
            onPressed: widget.onOpenWallet,
            icon: const Icon(Icons.account_balance_wallet_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _refreshPool();
          await _refreshLocal();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
          children: [
            _statusCard(),
            const SizedBox(height: 14),
            _earningsCard(account, perDay, payoutIn),
            const SizedBox(height: 14),
            _addressCard(),
            const SizedBox(height: 14),
            _deviceCard(),
            const SizedBox(height: 14),
            _honestyCard(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() => SectionCard(
        title: _running ? 'Mining now' : 'Not mining',
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: (_running ? kOk : kMuted).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _running ? 'running' : (_pauseReason ?? 'stopped'),
            style: TextStyle(
                color: _running ? kOk : kMuted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _running
                  ? 'Your phone is earning into ${widget.address.substring(0, 14)}… while it is '
                      'idle. The notification on your lock screen is the receipt.'
                  : (_pauseReason == null
                      ? 'Nothing is being mined right now. Nothing runs in the background until '
                          'you start it.'
                      : 'Paused by the SDK: $_pauseReason. It resumes by itself when the phone '
                          'is comfortable again.'),
              style: const TextStyle(color: kMuted, height: 1.5, fontSize: 13),
            ),
            if (_restartNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_restartNote, style: const TextStyle(color: kMuted, fontSize: 12, height: 1.45)),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _toggle,
                    icon: Icon(_running ? Icons.pause : Icons.play_arrow, size: 19),
                    label: Text(_running ? 'Stop mining' : 'Start mining'),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Notification permission',
                  onPressed: () async {
                    final granted = await ServiceBridge.hasNotificationPermission();
                    if (!granted) await ServiceBridge.requestNotificationPermission();
                  },
                  icon: const Icon(Icons.notifications_outlined),
                ),
              ],
            ),
            if (_recent.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _recent.take(3).join('\n'),
                style: const TextStyle(color: kMuted, fontSize: 11.5, height: 1.5),
              ),
            ],
          ],
        ),
      );

  Widget _earningsCard(PoolAccount? account, double? perDay, Duration? payoutIn) {
    if (account == null) {
      return const SectionCard(
        title: 'Your earnings',
        child: Text('Reading the pool…', style: TextStyle(color: kMuted)),
      );
    }
    if (account.error != null) {
      return SectionCard(
        title: 'Your earnings',
        trailing: TextButton(onPressed: _refreshPool, child: const Text('Retry')),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The pool did not answer just now, so these numbers are unknown rather than zero.',
              style: TextStyle(color: kMuted, height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(account.error!, style: const TextStyle(color: kMuted, fontSize: 11)),
          ],
        ),
      );
    }
    return SectionCard(
      title: 'Your earnings',
      trailing: _loadingAccount
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(onPressed: _refreshPool, child: const Text('Refresh')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'In the pool, not yet paid',
                  value: '${formatSugar(account.total)} SUGAR',
                  note: 'balance ${formatSugar(account.balance)} + immature ${formatSugar(account.immature)}',
                  color: kAccent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Already paid to you',
                  value: '${formatSugar(account.paid)} SUGAR',
                  note: 'sent to your wallet',
                  color: kOk,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Your devices hashrate',
                  value: formatHashrate(account.hashrate),
                  note: '${account.devices.length} device${account.devices.length == 1 ? '' : 's'} on this address',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Expected, at today\'s rate',
                  value: perDay == null ? '—' : '${formatSugar(perDay)} SUGAR/day',
                  note: perDay == null ? 'network rate unavailable' : 'chain issues 42.95 SUGAR every 5s',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            payoutIn == null
                ? 'The pool pays out on its own schedule once your balance is worth sending. '
                    'Anything below the pool\'s threshold keeps accumulating — it is not lost, '
                    'and it stays yours.'
                : 'At this rate, roughly ${formatDuration(payoutIn)} until the pool has enough to '
                    'pay out. It pays automatically; there is nothing to claim.',
            style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 8),
          Text(
            'The estimate assumes a phone holds the same share of the network\'s hashrate all '
            'day, which it never quite does. It is arithmetic from the chain\'s own numbers, not '
            'a promise. SUGAR is a small coin and currently trades for a fraction of a cent.',
            style: TextStyle(color: kMuted.withValues(alpha: 0.8), fontSize: 11, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _addressCard() => SectionCard(
        title: 'Your wallet address',
        trailing: IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.address));
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Address copied')));
          },
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(widget.address,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4)),
            const SizedBox(height: 8),
            const Text(
              'This is where your SUGAR is mined to. Coins sent here can only be moved with '
              'the key you saved — that is what "your wallet" means.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.45),
            ),
          ],
        ),
      );

  Widget _deviceCard() {
    final account = _account;
    return SectionCard(
        title: 'This device',
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Hashrate (live)',
                    value: formatHashrate(_stats.hashrate),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Shares accepted',
                    value: '${_stats.accepted}',
                    note: _stats.rejected == 0 ? null : '${_stats.rejected} rejected',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Mined today',
                    value: '${_status['minedMinutesToday'] ?? 0} min',
                    note: 'cap ${AppConfig.policy.dailyCapMinutes} min',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Your share of one core',
                    value: '${AppConfig.policy.cpuSharePercent}%',
                    note: 'pauses on heat, battery, data',
                  ),
                ),
              ],
            ),
            if ((account?.devices ?? []).isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Devices mining to this address', style: TextStyle(color: kMuted, fontSize: 12)),
              ),
              const SizedBox(height: 6),
              ...account!.devices.map((d) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(d.name,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                        ),
                        Text(formatHashrate(d.hashrate),
                            style: const TextStyle(fontSize: 12, color: kMuted)),
                      ],
                    ),
                  )),
            ],
          ],
        ),
      );
  }

  Widget _honestyCard() => const SectionCard(
        title: 'Worth knowing',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fact('One phone is not a mining rig',
                'A phone does roughly 100–400 hashes a second. On a small chain that is a real '
                'share of the network, and it is still pennies a day — do not expect a wage.'),
            _Fact('The notification stays',
                'Android kills a foreground service without a notification anyway, and mining '
                'that the owner cannot see is malware. There is no switch to hide it, in this '
                'app or in the SDK it uses.'),
            _Fact('Battery and heat are respected',
                'Mining pauses automatically when the battery is low, the phone is warm, or you '
                'are on mobile data. It resumes by itself when the phone is comfortable again.'),
            _Fact('This app is not on the Play Store',
                'Google Play prohibits on-device mining. Shipping here means sideloading or an '
                'enterprise/kiosk install, and that is a deliberate choice, not a limitation '
                'being hidden.'),
          ],
        ),
      );
}

class _Fact extends StatelessWidget {
  final String title;
  final String body;
  const _Fact(this.title, this.body);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            const SizedBox(height: 2),
            Text(body, style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5)),
          ],
        ),
      );
}
