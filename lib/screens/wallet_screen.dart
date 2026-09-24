/// The wallet screen: show it, back it up, import a different one, erase it.
///
/// Erasing is deliberately awkward to reach and says what it actually does: the
/// SUGAR at the address stays on the chain, and without the key it is unreachable.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';
import 'package:sugar_wallet/sugar_wallet.dart';

import '../app_config.dart';
import '../services/wallet_store.dart';
import '../theme.dart';

class WalletScreen extends StatefulWidget {
  final SugarWallet? wallet;
  final String address;
  final Future<void> Function() onChanged;
  const WalletScreen({
    super.key,
    required this.wallet,
    required this.address,
    required this.onChanged,
  });

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  bool _showKey = false;
  Map<String, String?> _details = const {};
  final _importController = TextEditingController();
  String? _importError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WalletStore.details().then((d) {
      if (mounted) setState(() => _details = d);
    });
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  Future<void> _copyBackup() async {
    final w = widget.wallet;
    if (w == null) return;
    await Clipboard.setData(ClipboardData(text: WalletStore.backupJson(w, _details)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup copied — store it off this phone')));
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _importError = null;
    });
    try {
      final wallet = SugarWallet.import(_importController.text);
      // Stop the old miner before pointing mining somewhere else: two addresses
      // submitting shares at once would be two half-answers to one question.
      await SugarMinerSdk.instance?.stop();
      await WalletStore.save(wallet);
      await SugarMinerSdk.install(
        config: AppConfig.forAddress(wallet.address),
        policy: AppConfig.policy,
        autoStart: false,
      );
      await widget.onChanged();
      if (!mounted) return;
      setState(() {
        _importController.clear();
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wallet imported. Mining will use it when you start it.')));
    } catch (e) {
      setState(() {
        _importError = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _erase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('Erase this wallet from the phone?'),
        content: const Text(
          'The app stops mining and forgets the key. Any SUGAR already at the address stays '
          'on the chain — but without your backup, nobody can ever move it again. There is no '
          'reset and no recovery.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await SugarMinerSdk.instance?.stop(byUser: true);
    await WalletStore.erase();
    await widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.wallet;
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet & backup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          SectionCard(
            title: 'Address',
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.address));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Address copied')));
              },
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(widget.address,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4)),
                if (_details['createdAt'] != null) ...[
                  const SizedBox(height: 6),
                  Text('Created ${_details['createdAt']}',
                      style: const TextStyle(color: kMuted, fontSize: 11.5)),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Sugarchain addresses start with sugar1q. The wallet also has a legacy '
                  '"S…" form, which some old wallets still want:',
                  style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
                ),
                if (w != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(w.legacyAddress,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Backup',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The key below is the wallet. Anyone who has it can spend your SUGAR; '
                  'nobody without it can, including this app\'s developer.',
                  style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 12),
                if (w == null)
                  const Text(
                    'The key could not be read from this device\'s secure storage, so it cannot '
                    'be shown here. Mining still uses the address. If you have a backup, import '
                    'it below; if you do not, the SUGAR at this address can no longer be moved.',
                    style: TextStyle(color: kWarn, fontSize: 12.5, height: 1.5),
                  )
                else ...[
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => _showKey = !_showKey),
                        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility, size: 18),
                        label: Text(_showKey ? 'Hide the key' : 'Show the key'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _copyBackup,
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('Copy backup'),
                      ),
                    ],
                  ),
                  if (_showKey) ...[
                    const SizedBox(height: 12),
                    const Text('WIF (import this into a wallet app)',
                        style: TextStyle(color: kMuted, fontSize: 11.5)),
                    const SizedBox(height: 4),
                    SelectableText(w.wif,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
                    const SizedBox(height: 10),
                    const Text('Hex (the raw key)', style: TextStyle(color: kMuted, fontSize: 11.5)),
                    const SizedBox(height: 4),
                    SelectableText(w.privateKeyHex,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          const SectionCard(
            title: 'How to actually spend your SUGAR',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Step('1', 'Wait for the pool to pay out',
                    'The pool holds your balance and sends it to this address automatically once '
                    'it is worth sending. Watch it on the home screen.'),
                _Step('2', 'Import the key into a Sugarchain wallet',
                    'Any wallet that accepts a WIF can import it — the key above is in exactly '
                    'that format. From there the coins are spendable, sendable or tradeable like '
                    'any other SUGAR.'),
                _Step('3', 'Or just keep the backup',
                    'The coins do not expire. A key in a drawer is still a key; the only thing '
                    'that destroys a wallet is losing it.'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Mine to a different wallet',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Paste a WIF or a 64-character hex key. This replaces the wallet on this '
                  'device and stops mining until you start it again.',
                  style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _importController,
                  obscureText: true,
                  cursorColor: kAccent,
                  decoration: InputDecoration(
                    hintText: 'K… or 64 hex characters',
                    filled: true,
                    fillColor: kPanel2,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kLine)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kLine)),
                  ),
                ),
                if (_importError != null) ...[
                  const SizedBox(height: 8),
                  Text(_importError!, style: const TextStyle(color: kBad, fontSize: 12)),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _import,
                      child: Text(_busy ? 'Working…' : 'Import and switch'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(onPressed: _erase, child: const Text('Erase this device')),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'No account, no server, no recovery phrase sent anywhere. This app has no idea who '
            'you are — it only knows a public address.',
            style: TextStyle(color: kMuted, fontSize: 11.5, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String title;
  final String body;
  const _Step(this.number, this.title, this.body);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
              child: Text(number,
                  style: const TextStyle(
                      color: Color(0xFF111111), fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(body, style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      );
}
