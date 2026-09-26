/// The send screen: pick a destination, name an amount, look at the fee, sign.
///
/// The order matters and it is the whole design. Nothing is signed until the user
/// has seen the fee, the change and the total on one card, because those three
/// numbers are the transaction: the amount is what the recipient gets, the fee is
/// what the minter gets, and the total is what leaves the wallet. A wallet that
/// hides the fee until afterwards has decided the fee is not the user's business.
///
/// Everything up to that card is a read — the address's coins, the chain's fee
/// estimate. The signature is made on this device, in the SDK's own ECDSA, and
/// what leaves the phone is a transaction that anyone may see, which is the point
/// of a transaction. The key itself never moves.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sugar_wallet/sugar_wallet.dart';

import '../services/chain_api.dart';
import '../services/wallet_store.dart';
import '../theme.dart';

/// A whole SUGAR, in satoshis. The chain has eight decimal places and the wallet
/// does all of its arithmetic in the smallest one, so nothing is ever rounded
/// twice or shown as a number it is not.
const int kSatsPerSugar = 100000000;

/// Reads "1.25" as 125000000 satoshis, exactly, with no floating point anywhere
/// near it. Returns null for anything that is not a plain non-negative decimal —
/// including "", "1,5", "1e3" and "1.234567891" — because an amount that has to be
/// guessed at is an amount that can be sent wrong.
int? parseSugar(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final parts = t.split('.');
  if (parts.length > 2) return null;
  final whole = parts[0].isEmpty ? '0' : parts[0];
  final frac = parts.length == 2 ? parts[1] : '';
  if (frac.length > 8) return null;
  if (!RegExp(r'^\d+$').hasMatch(whole)) return null;
  if (frac.isNotEmpty && !RegExp(r'^\d+$').hasMatch(frac)) return null;
  final w = int.tryParse(whole);
  final f = frac.isEmpty ? 0 : int.parse(frac.padRight(8, '0'));
  if (w == null) return null;
  return w * kSatsPerSugar + f;
}

/// Satoshis as a SUGAR amount, with all eight places and no trailing zeros
/// beyond the second — "0.000142" reads better than "0.00014200", and "1.5"
/// reads better than "1.50000000".
String sugarFromSats(int sats) {
  final whole = sats ~/ kSatsPerSugar;
  final frac = sats % kSatsPerSugar;
  if (frac == 0) return '$whole';
  final digits = frac.toString().padLeft(8, '0').replaceAll(RegExp(r'0+$'), '');
  return '$whole.$digits';
}

class SendScreen extends StatefulWidget {
  /// The address this wallet spends from, for the change to come back to.
  final String address;

  /// The chain, and the key. Both are injectable so the tests can run against a
  /// canned chain and a known key; in the app they are the real ones and there is
  /// no other way to reach them.
  final ChainApi api;
  final Future<SugarWallet?> Function() loadWallet;

  const SendScreen({
    super.key,
    required this.address,
    this.api = const ChainApi(),
    this.loadWallet = WalletStore.load,
  });

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _to = TextEditingController();
  final _amount = TextEditingController();

  /// The key that signs, read from the keystore when this screen opens and kept
  /// only as long as the screen is on screen. It is never written anywhere else.
  SugarWallet? _wallet;
  List<Utxo>? _utxos;
  int? _feeRate;
  String? _loadError;
  bool _loading = true;

  SendResult? _plan;
  String? _planError;
  bool _sending = false;
  String? _txid;

  /// Set only if the node reports an id that is not the one this phone computed
  /// from the bytes it signed. It should never happen, and if it does the user is
  /// told rather than shown the node's answer as the truth.
  String? _txidMismatch;
  String? _sendError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      // Three things in parallel: what the chain says this address can spend,
      // what it charges, and the key this device would sign with.
      final results = await Future.wait([
        widget.api.unspent(widget.address),
        widget.api.feeRatePerVByte(),
        widget.loadWallet(),
      ]);
      if (!mounted) return;
      setState(() {
        _utxos = results[0] as List<Utxo>;
        _feeRate = results[1] as int;
        _wallet = results[2] as SugarWallet?;
        _loadError = _wallet == null
            ? 'The key could not be read from this phone\'s keystore, so nothing can '
                'be signed. That is a fault on this device, not with the chain.'
            : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'The chain could not be reached: $e';
        _loading = false;
      });
    }
  }

  int get _balanceSats =>
      (_utxos ?? const <Utxo>[]).fold(0, (sum, u) => sum + u.sats);

  /// How many of the coins are legacy `S…` ones — the expensive kind to spend.
  int get legacyCount => (_utxos ?? const <Utxo>[]).where((u) => !u.segwit).length;

  /// Builds the transaction and stops there. Signing is a separate, deliberate
  /// press — this one only computes, and can be repeated as often as the user
  /// changes their mind about the amount.
  /// Fills the destination from the clipboard.
  ///
  /// Pasting by hand means a long press, a drag to the right item in a system menu,
  /// and then checking afterwards that the whole address arrived. This is one tap,
  /// and the address is checked the moment it lands.
  Future<void> _pasteAddress() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('There is nothing to paste')));
      return;
    }
    // Some apps copy an address with a scheme or a label attached; a bech32 or
    // base58 address is the last whitespace-separated word either way, so that is
    // the part to try.
    final candidate = text.split(RegExp(r'\s+')).last;
    _to.text = candidate;
    setState(() => _plan = null);
    if (!mounted) return;
    final ok = checkAddress(candidate).where((r) => r.ok == false).isEmpty;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Address pasted'
          : 'Pasted — but that does not look like a SUGAR address'),
    ));
  }

  void _review() {
    final wallet = _wallet;
    final to = _to.text.trim();
    final sats = parseSugar(_amount.text);
    setState(() {
      _txid = null;
      _txidMismatch = null;
      _sendError = null;
      _planError = null;
      _plan = null;
    });
    if (wallet == null) {
      setState(() => _planError = 'There is no key loaded in this app.');
      return;
    }
    if (sats == null || sats <= 0) {
      setState(() => _planError = 'Enter an amount, like 1.5 or 0.0001.');
      return;
    }
    try {
      final coins = _utxos ?? const <Utxo>[];
      final plan = SendPlan.prepare(
        available: [for (final u in coins) Spent(u, Uint8List(0))],
        amountSats: sats,
        toAddress: to,
        changeAddress: widget.address,
        feeRatePerVByte: _feeRate ?? 1,
        network: wallet.network,
        // A coin pasted in from Core or the web wallet is a legacy one, and a
        // legacy input is 148 vB against a segwit input's 68. Guessing segwit
        // here would under-price the fee and the signature would be the wrong
        // shape entirely.
        segwitByOutpoint: {for (final u in coins) u.key: u.segwit},
      );
      setState(() => _plan = plan);
    } catch (e) {
      setState(() => _planError = _explain('$e'));
    }
  }

  /// Sign on this device, then hand the bytes to the network.
  Future<void> _signAndSend() async {
    final plan = _plan;
    final wallet = _wallet;
    if (plan == null || wallet == null) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      // The key that signs is looked up per input: an input this wallet does not
      // own gets no signature and no guess.
      final signed = signAll(plan, (_) => wallet.privateKey);
      final raw = signed.serialize();
      // The id is this phone's own arithmetic on the bytes this phone signed — the
      // node's answer is a confirmation, not the source of truth.
      final ours = signed.txid;
      final reported = await widget.api.broadcast(_hex(raw));
      if (!mounted) return;
      setState(() {
        _sending = false;
        _txid = ours;
        _txidMismatch = reported == ours ? null : reported;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = _explain('$e');
      });
    }
  }

  static String _hex(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// Errors from three different layers arrive here as one-line strings. The
  /// node's own complaint is passed through, because it is the true one and the
  /// only clue there is; the rest is turned into something a person can act on.
  String _explain(String raw) {
    final t = raw.replaceFirst(RegExp(r'^(StateError|ArgumentError|FormatException|'
        r'HttpException|Exception):\s*'), '').trim();
    if (t.contains('bad-txns-inputs-missingorspent') ||
        t.contains('missingorspent') ||
        t.contains('insufficient')) {
      return 'The chain says these coins have already been spent. Something else '
          'moved them first — pull down to refresh and look at the balance again.';
    }
    if (t.contains('dust')) {
      return 'That amount is too small to send: below 0.00000546 SUGAR an output '
          'costs more to spend than it is worth, and nodes will not relay it.';
    }
    if (t.contains('has no unspent outputs')) {
      return 'There is nothing at this address to spend yet. Coins appear here a '
          'few minutes after they are mined or sent.';
    }
    if (t.contains('not enough to cover') || t.contains('do not cover the amount')) {
      return 'That is more than this address holds. It can spend '
          '${sugarFromSats(_balanceSats)} SUGAR right now, and the amount plus the '
          'fee has to come out of that.';
    }
    if (t.contains('address')) return t;
    return t.isEmpty ? 'Something went wrong, and the chain gave no reason.' : t;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send SUGAR')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          _balanceCard(),
          const SizedBox(height: 14),
          _formCard(),
          if (_planError != null) ...[
            const SizedBox(height: 14),
            _errorCard(_planError!, title: 'Cannot build that yet'),
          ],
          if (_plan != null) ...[
            const SizedBox(height: 14),
            _reviewCard(_plan!),
          ],
          if (_sendError != null) ...[
            const SizedBox(height: 14),
            _errorCard(_sendError!),
          ],
          if (_txid != null) ...[
            const SizedBox(height: 14),
            _sentCard(_txid!),
          ],
          const SizedBox(height: 14),
          const _FeeFacts(),
        ],
      ),
    );
  }

  Widget _balanceCard() {
    final rate = _feeRate;
    return SectionCard(
      title: 'Spendable here',
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 18),
        onPressed: _loading ? null : _load,
      ),
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            )
          : _loadError != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_loadError!,
                        style: const TextStyle(color: kWarn, fontSize: 12.5, height: 1.5)),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Try again'),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${sugarFromSats(_balanceSats)} SUGAR',
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700, color: kInk)),
                    const SizedBox(height: 4),
                    Text(
                      '${_utxos!.length} unspent output${_utxos!.length == 1 ? '' : 's'}'
                      '${rate == null ? '' : ' · network fee $rate sat/vB'}',
                      style: const TextStyle(color: kMuted, fontSize: 12),
                    ),
                    if (legacyCount > 0) ...[
                      const SizedBox(height: 6),
                      Text(
                        '$legacyCount of them ${legacyCount == 1 ? 'is a legacy S… coin' : 'are legacy S… coins'}, '
                        'which cost more to spend than a sugar1q… one. Nothing to fix — this is just '
                        'what they are.',
                        style: const TextStyle(color: kMuted, fontSize: 12, height: 1.45),
                      ),
                    ],
                    if (_balanceSats == 0) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Coins sent to this address take a few minutes to appear. If you '
                        'paid for this key somewhere else, give the chain a moment to catch '
                        'up, then refresh.',
                        style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _formCard() {
    final ready = !_loading && _loadError == null;
    return SectionCard(
      title: 'To',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _to,
            enabled: _txid == null,
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              hintText: 'sugar1q…  or  S…   (an address to send to)',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _txid != null
                  ? null
                  : IconButton(
                      tooltip: 'Paste from clipboard',
                      icon: const Icon(Icons.content_paste, size: 18),
                      onPressed: _pasteAddress,
                    ),
            ),
            onChanged: (_) => setState(() => _plan = null),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            enabled: _txid == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(
              hintText: 'amount in SUGAR, like 1.5 or 0.0001',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _balanceSats > 0
                  ? TextButton(
                      onPressed: _txid != null
                          ? null
                          : () {
                              // "All" is the balance minus the fee for a
                              // one-output transaction; the exact figure is
                              // recomputed and shown on the card before signing.
                              // The coin kinds matter: a legacy input is 148 vB
                              // against a segwit one's 68, and a fee computed on
                              // the cheaper assumption would leave "All" a little
                              // too large to actually send.
                              final coins = _utxos ?? const <Utxo>[];
                              final fee = SendPlan.estimateVBytes(
                                    coins.length,
                                    1,
                                    segwitInputs:
                                        coins.where((u) => u.segwit).length,
                                  ) *
                                  (_feeRate ?? 1);
                              final all = _balanceSats - fee;
                              setState(() {
                                _amount.text = all > 0 ? sugarFromSats(all) : '';
                                _plan = null;
                              });
                            },
                      child: const Text('All'),
                    )
                  : null,
            ),
            onChanged: (_) => setState(() => _plan = null),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: ready && !_sending ? _review : null,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Review'),
          ),
          if (ready) ...[
            const SizedBox(height: 10),
            const Text(
              'Review builds the transaction and shows you the fee. Nothing is signed '
              'until you press send, and nothing leaves this phone until you do.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _reviewCard(SendResult plan) {
    final total = plan.totalSpentSats;
    return SectionCard(
      title: 'This is what will leave the wallet',
      trailing: _plan != null && _txid == null
          ? IconButton(
              tooltip: 'Start over',
              icon: const Icon(Icons.close, size: 18),
              onPressed: _sending ? null : () => setState(() => _plan = null),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('To', _short(_to.text.trim())),
          _row('Amount', '${sugarFromSats(plan.amountSats)} SUGAR', bold: true),
          _row('Network fee',
              '${sugarFromSats(plan.feeSats)} SUGAR  (${plan.inputs.length} '
                  'input${plan.inputs.length == 1 ? '' : 's'}, '
                  '${plan.estimatedVBytes} vB signed)'),
          if (plan.changeSats > 0)
            _row('Change back to you', '${sugarFromSats(plan.changeSats)} SUGAR')
          else
            _row('Change back to you', 'none — the remainder is in the fee'),
          const Divider(height: 22),
          _row('Total', '${sugarFromSats(total)} SUGAR', bold: true),
          const SizedBox(height: 12),
          if (_txid == null)
            FilledButton.icon(
              onPressed: _sending ? null : _signAndSend,
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.lock_outline, size: 18),
              label: Text(_sending ? 'Signing and broadcasting…' : 'Sign and send'),
            ),
          const SizedBox(height: 10),
          const Text(
            'Signing happens on this phone, with the key in its keystore. The '
            'transaction is public once it is broadcast — that is what a transaction '
            'is — but the key is not in it and cannot be worked out from it.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _sentCard(String txid) => SectionCard(
        title: 'Sent',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The chain accepted the transaction. It is in the mempool now and will '
              'be mined into a block if the fee was enough — usually a few minutes on '
              'SUGAR.',
              style: TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text('Transaction id', style: TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(txid,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.45)),
            if (_txidMismatch != null) ...[
              const SizedBox(height: 10),
              Text(
                'Note: the node answered with a different id ($_txidMismatch). The id '
                'above is computed from the bytes this phone signed, so it is the one '
                'to search for — but the difference is worth knowing about.',
                style: const TextStyle(color: kWarn, fontSize: 12, height: 1.5),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: txid));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Transaction id copied')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy transaction id'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => setState(() {
                _plan = null;
                _txid = null;
                _amount.clear();
                _to.clear();
                _load();
              }),
              child: const Text('Send something else'),
            ),
          ],
        ),
      );

  Widget _errorCard(String message, {String title = 'Not sent'}) => SectionCard(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message,
                style: const TextStyle(color: kBad, fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 10),
            const Text(
              'Nothing was broadcast: this wallet signs a transaction and then hands '
              'over the finished bytes, so a failure before that point sends nothing.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      );

  static String _short(String address) => address.length <= 20
      ? address
      : '${address.substring(0, 11)}…${address.substring(address.length - 6)}';

  static Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: kMuted, fontSize: 12.5, height: 1.45)),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
}

class _FeeFacts extends StatelessWidget {
  const _FeeFacts();

  @override
  Widget build(BuildContext context) => const SectionCard(
        title: 'About the fee',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fact(
              'Where the number comes from',
              'The chain\'s own node is asked what a transaction should pay right now, '
                  'and the answer is a rate per byte, not a total. The total depends on '
                  'how many coins get used up and how many outputs come out, which is '
                  'why it is worked out here and shown to you before anything is signed.',
            ),
            _Fact(
              'A round number of coins is the cheap case',
              'Each coin spent adds about 68 bytes, so sending one large coin is '
                  'cheaper than sending five small ones for the same amount. The wallet '
                  'picks the largest first for that reason.',
            ),
            _Fact(
              'Dust is refused, not rounded',
              'Below 0.00000546 SUGAR an output costs more to spend than it is worth, '
                  'so instead of leaving you an unspendable coin the wallet adds the '
                  'remainder to the fee. That only ever happens when the change was '
                  'going to be dust anyway.',
            ),
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
