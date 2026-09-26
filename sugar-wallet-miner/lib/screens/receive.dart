/// The receive screen: a scannable code, the same address as text, and a plain
/// explanation of what the code can and cannot do.
///
/// This wallet has one key and two addresses — a `sugar1q…` one and a legacy `S…`
/// one, both of them this same wallet. Which one to hand out depends on the other
/// side: modern wallets and this app's own miner want the `sugar1q…` form, while a
/// few old tools only accept the `S…` one. The switch here exists so the answer to
/// "which address should I give them?" is visible on the screen rather than
/// something the user has to know.
///
/// The code holds a public address and nothing else — there is no key material
/// anywhere near this screen, and the wording says so, because "QR code" makes
/// people reasonably suspicious about wallets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets/qr.dart';
import '../widgets/qr_view.dart';

class ReceiveScreen extends StatefulWidget {
  /// The `sugar1q…` (native segwit) address. This is the one the miner pays to.
  final String address;

  /// The legacy `S…` (P2PKH) address for the same key. Shown as a second option
  /// when it is known; when it is not, this screen is simply the segwit one.
  final String? legacyAddress;

  /// The app this wallet belongs to, shown as the title of the share sheet when
  /// the user sends the address to someone.
  final String appName;

  const ReceiveScreen({
    super.key,
    required this.address,
    this.legacyAddress,
    this.appName = 'SUGAR Wallet',
  });

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  QrCode? _code;
  String? _error;

  /// Which of the two addresses is on screen. It starts on the segwit one, because
  /// that is what this app mines to and what modern wallets want.
  bool _legacy = false;

  String get _shown => _legacy ? (widget.legacyAddress ?? widget.address) : widget.address;

  @override
  void initState() {
    super.initState();
    _encode();
  }

  /// Encoding is synchronous and cheap (a few hundred microseconds), but a wallet
  /// address is not always a valid byte string for the encoder's 1,000 character
  /// ceiling, so a failure has to be shown rather than thrown.
  void _encode() {
    try {
      setState(() {
        _code = QrCode.encode(_shown);
        _error = null;
      });
    } catch (e) {
      setState(() {
        _code = null;
        _error = '$e';
      });
    }
  }

  void _show({required bool legacy}) {
    if (legacy && widget.legacyAddress == null) return;
    setState(() => _legacy = legacy);
    _encode();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _shown));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Address copied')));
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return Scaffold(
      appBar: AppBar(title: const Text('Receive SUGAR')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          if (widget.legacyAddress != null) ...[
            _kindSwitch(),
            const SizedBox(height: 14),
          ],
          if (code == null)
            SectionCard(
              title: 'This address cannot be drawn as a code',
              child: Text(
                _error ?? 'The QR encoder refused the address.',
                style: const TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
              ),
            )
          else
            _codeCard(code),
          const SizedBox(height: 14),
          _addressCard(),
          const SizedBox(height: 14),
          const _CodeFacts(),
        ],
      ),
    );
  }

  /// The two addresses this one key has. Choosing is a real choice — an old
  /// wallet that cannot parse `sugar1q…` will refuse the payment outright — so the
  /// difference is spelled out rather than left to a tooltip.
  Widget _kindSwitch() {
    return SectionCard(
      title: 'Which address to give them',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('sugar1q…')),
              ButtonSegment(value: true, label: Text('S…')),
            ],
            selected: {_legacy},
            onSelectionChanged: (s) => _show(legacy: s.first),
          ),
          const SizedBox(height: 10),
          Text(
            _legacy
                ? 'The legacy form. Use it for an old wallet or exchange that refuses a '
                    'sugar1q… address. It is the same wallet, the same key and the same '
                    'coins — but a coin that arrives here costs more to spend later, so '
                    'prefer the other one when you are given the choice.'
                : 'The native segwit form, which is what this app mines to. Cheaper to '
                    'spend from and what modern wallets want. Only give the other form if '
                    'a sender insists they cannot use this one.',
            style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              Icon(Icons.check_circle_outline, size: 15, color: kOk),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Both of these are this wallet. SUGAR sent to either one arrives, and '
                  'this app can spend from either one.',
                  style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _codeCard(QrCode code) => SectionCard(
        title: 'Scan to pay this wallet',
        child: Column(
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: QrView(code: code, size: 236),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'The code contains the address only. Anyone can use it to send SUGAR here, '
              'and nobody can use it to take SUGAR out — spending needs the key, which '
              'never leaves this phone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      );

  Widget _addressCard() => SectionCard(
        title: 'Or send the address itself',
        trailing: IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: _copy,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              _shown,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy address'),
            ),
          ],
        ),
      );
}

class _CodeFacts extends StatelessWidget {
  const _CodeFacts();

  @override
  Widget build(BuildContext context) => const SectionCard(
        title: 'About this code',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CodeFact(
              'It is your public address',
              'A Sugarchain address starts with "sugar1". It is a destination, like an '
                  'account number: safe to show, safe to share, safe to print.',
            ),
            _CodeFact(
              'Nothing secret is inside the square',
              'The QR holds those same characters and a checksum, so a scanner can '
                  'notice a typo. The private key is in this phone\'s keystore and is '
                  'never drawn on screen.',
            ),
            _CodeFact(
              'Test it with a small amount first',
              'Crypto transfers cannot be reversed, and SUGAR is a small chain with few '
                  'places to buy or sell it. Send a little, confirm it arrives, then send '
                  'the rest.',
            ),
          ],
        ),
      );
}

class _CodeFact extends StatelessWidget {
  final String title;
  final String body;
  const _CodeFact(this.title, this.body);

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
