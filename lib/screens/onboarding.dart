/// First run: create the wallet, make the user save it, then ask consent.
///
/// The keys here are the user's own, so the app must not be casual about them: the
/// backup step is a gate, not a suggestion, and the consent step is the SDK's own
/// screen fed with this app's disclosure — the same screen (and the same
/// guarantees) a developer-hosted app would show.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';
import 'package:sugar_wallet/sugar_wallet.dart';

import '../app_config.dart';
import '../services/wallet_store.dart';
import '../theme.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, backup, consent }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.welcome;
  SugarWallet? _wallet;
  bool _savedIt = false;
  bool _busy = false;
  String? _error;

  Future<void> _createWallet() async {
    setState(() => _busy = true);
    try {
      final w = await WalletStore.create();
      setState(() {
        _wallet = w;
        _step = _Step.backup;
      });
    } catch (e) {
      setState(() => _error = 'Could not create a wallet: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _askConsent() async {
    final wallet = _wallet!;
    // The SDK's own consent screen, fed with this app's disclosure. Passing the
    // miner means the "yes" is recorded by the SDK itself (versioned against the
    // notice it showed), not by a flag this app could quietly set on its own.
    final miner = await SugarMinerSdk.install(
      config: AppConfig.forAddress(wallet.address),
      policy: AppConfig.policy,
      autoStart: false,
    );
    if (!mounted) return;

    final accepted = await SugarConsentSheet.show(
      context,
      miner: miner,
      appName: AppConfig.appName,
    );
    if (!accepted || !mounted) return;

    setState(() => _busy = true);
    // The two permissions Android will not let anyone take silently. Both are the
    // user's own taps in Android's own dialogs — the SDK asks, it cannot grant.
    await ServiceBridge.requestNotificationPermission();
    if (mounted) {
      await ServiceBridge.requestIgnoreBatteryOptimizations();
    }
    if (!mounted) return;
    await miner.start();
    setState(() => _busy = false);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: switch (_step) {
                _Step.welcome => _welcome(),
                _Step.backup => _backup(),
                _Step.consent => _consent(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcome() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.currency_bitcoin, size: 52, color: kAccent),
          const SizedBox(height: 18),
          const Text('Your phone, your wallet, your SUGAR',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700, height: 1.25)),
          const SizedBox(height: 14),
          const Text(
            'This app gives you a Sugarchain wallet of your own — created here, on this '
            'device — and then mines SUGAR straight into it using the processing power '
            'your phone is not using.',
            style: TextStyle(color: kMuted, height: 1.55),
          ),
          const SizedBox(height: 18),
          const _Bullet('Nobody else can spend it', 'The private key never leaves this phone. '
              'There is no account, no server holding your coins, and no way for anyone — '
              'including whoever built this app — to take them.'),
          const _Bullet('You will see it running', 'A notification stays on screen the whole '
              'time mining happens, with a Stop button. That is not optional, by design.'),
          const _Bullet('It stays out of your way', 'Mining pauses by itself when the phone '
              'is hot, low on battery, or on mobile data.'),
          const SizedBox(height: 22),
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: kBad)),
            const SizedBox(height: 12),
          ],
          FilledButton(
            onPressed: _busy ? null : _createWallet,
            child: Text(_busy ? 'Creating your wallet…' : 'Create my wallet'),
          ),
          const SizedBox(height: 10),
          const Text(
            'You will be asked to save a backup before mining can start. That backup is the '
            'only way to ever move the coins, so keep it somewhere safe.',
            style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
          ),
        ],
      );

  Widget _backup() {
    final w = _wallet!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Save this now', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text(
          'This is your wallet. The address is where your SUGAR will be mined to; the key '
          'below is what lets you spend it. Lose the key and the coins are gone — not '
          'frozen, gone, and no support desk on earth can help.',
          style: TextStyle(color: kMuted, height: 1.55),
        ),
        const SizedBox(height: 18),
        _LabeledValue(label: 'Your address', value: w.address, mono: true),
        const SizedBox(height: 10),
        _LabeledValue(label: 'Private key (WIF)', value: w.wif, mono: true),
        const SizedBox(height: 10),
        _LabeledValue(label: 'Private key (hex)', value: w.privateKeyHex, mono: true),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () async {
            final json = WalletStore.backupJson(w, await WalletStore.details());
            await Clipboard.setData(ClipboardData(text: json));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Backup copied. Paste it somewhere that is not this phone.'),
              ));
            }
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy the backup file'),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          value: _savedIt,
          onChanged: (v) => setState(() => _savedIt = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('I have written down or copied this key',
              style: TextStyle(fontSize: 14.5)),
        ),
        FilledButton(
          onPressed: _savedIt ? () => setState(() => _step = _Step.consent) : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Widget _consent() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('One permission screen, then it runs',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(
            'The next screen is the mining disclosure: it says exactly what this app does, '
            'what it uses, and how to stop it. Your wallet is ${_wallet!.address}',
            style: const TextStyle(color: kMuted, height: 1.55),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _busy ? null : _askConsent,
            child: Text(_busy ? 'Starting…' : 'Read the disclosure and decide'),
          ),
          const SizedBox(height: 10),
          const Text('Declining is fine — the app works either way, it just will not mine.',
              style: TextStyle(color: kMuted, fontSize: 12.5)),
        ],
      );
}

class _Bullet extends StatelessWidget {
  final String title;
  final String body;
  const _Bullet(this.title, this.body);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Icon(Icons.check_circle_outline, size: 18, color: kOk),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(body, style: const TextStyle(color: kMuted, fontSize: 13, height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _LabeledValue extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  const _LabeledValue({required this.label, required this.value, this.mono = false});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(
              value,
              style: TextStyle(
                fontFamily: mono ? 'monospace' : null,
                fontSize: mono ? 12.5 : 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      );
}
