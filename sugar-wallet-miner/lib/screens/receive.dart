/// The receive screen: one scannable code, the same address as text, and a plain
/// explanation of what the code can and cannot do.
///
/// The code holds the public address and nothing else — there is no key material
/// anywhere near this screen, and the wording says so, because "QR code" makes
/// people reasonably suspicious about wallets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets/qr.dart';
import '../widgets/qr_view.dart';

class ReceiveScreen extends StatefulWidget {
  final String address;

  /// The app this wallet belongs to, shown as the title of the share sheet when
  /// the user sends the address to someone.
  final String appName;

  const ReceiveScreen({
    super.key,
    required this.address,
    this.appName = 'SUGAR Wallet',
  });

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  QrCode? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Encoding is synchronous and cheap (a few hundred microseconds), but a
    // wallet address is not always a valid byte string for the encoder's 1,000
    // character ceiling, so a failure has to be shown rather than thrown.
    try {
      _code = QrCode.encode(widget.address);
    } catch (e) {
      _error = '$e';
    }
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.address));
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
              widget.address,
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
