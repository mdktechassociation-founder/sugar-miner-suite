// The send screen is where a mistake costs money, so the tests here are about the
// things a wallet can get wrong and still look confident: a fee the user never saw,
// an amount parsed from text into the wrong number of satoshis, a rejection that is
// shown as a success, and signing twice by double-tapping.
//
// The chain is a canned one and the key is a fixed one, so none of this touches a
// network or a keystore.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sugar_wallet/sugar_wallet.dart';
import 'package:sugar_wallet_miner/screens/send.dart';
import 'package:sugar_wallet_miner/services/chain_api.dart';

/// The key embit also holds, so the transaction this test signs is the one the
/// independent implementation checked in `packages/sugar_wallet/test/spend_vectors.dart`.
const _wif = 'L5iAcaU29iBscTY2XH9sd2Esj9gM5b3f7wyk7aHKLpDHtCEzQZXm';
const _ownAddress = 'sugar1q3828kzacg6yp9f5tply4yrtgtu20kqt3wu52j6';
const _destAddress = 'sugar1ql3e9pgs3mmwuwrh95fecme0s0qtn2880p96h8t';
const _utxoTxid = '0100000000000000000000000000000000000000000000000000000000000000';

/// A chain that answers the three questions with fixed answers, and remembers what
/// it was asked to broadcast.
class FakeChain extends ChainApi {
  FakeChain({this.utxos = 1, this.sats = 100000000, this.rate = 1, this.reject});

  final int utxos;
  final int sats;
  final int rate;

  /// When set, the broadcast fails with this — the node's own words.
  final String? reject;
  final List<String> broadcasted = [];
  int unspentCalls = 0;

  @override
  Future<List<Utxo>> unspent(String address) async {
    unspentCalls++;
    return [
      for (var i = 0; i < utxos; i++)
        Utxo(txid: _utxoTxid, vout: i, sats: sats),
    ];
  }

  @override
  Future<int> feeRatePerVByte() async => rate;

  @override
  Future<String> broadcast(String rawHex) async {
    broadcasted.add(rawHex);
    final why = reject;
    if (why != null) throw FormatException(why);
    return '57c065cacf6e7f24684a7bb669ad6a172ce2273f569b0eb5fbd2c5f8c13a42d3';
  }
}

/// A chain that offers one legacy `S…` coin instead of a segwit one — what a wallet
/// looks like after a WIF is pasted in from Core or the web wallet, or after
/// somebody pays the legacy address.
class LegacyChain extends FakeChain {
  LegacyChain();
  @override
  Future<List<Utxo>> unspent(String address) async => [
        Utxo(txid: _utxoTxid, vout: 0, sats: sats, segwit: false),
      ];
}

Widget _screen(FakeChain chain, {String address = _ownAddress}) => MaterialApp(
      home: SendScreen(
        address: address,
        api: chain,
        loadWallet: () async => SugarWallet.import(_wif),
      ),
    );

/// The screen shows a progress bar while it loads, so `pumpAndSettle` would spin
/// forever. Three pumps is enough for the three futures and the rebuild.
/// A screen tall enough for the whole card to be on it. Otherwise the buttons sit
/// below the fold and a tap lands on nothing — which is exactly the kind of test
/// that passes while the screen is broken.
Future<void> _pumpScreen(WidgetTester tester, FakeChain chain) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_screen(chain));
  await _settle(tester);
}

/// The buttons carry an icon and a label, so they are found by the label they show.
Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(FilledButton, label).first);
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A displayed txid is the reverse of the bytes on the wire.
String _wireOrder(String txid) {
  final out = StringBuffer();
  for (var i = txid.length; i > 0; i -= 2) {
    out.write(txid.substring(i - 2, i));
  }
  return out.toString();
}

String _hash160Hex(String address) {
  final decoded = bech32Decode(address);
  if (decoded == null) throw StateError('the test address is not a bech32 address');
  final program = decoded.program;
  return toHex(program.sublist(program.length - 20));
}

/// The compressed public key of the test wallet — the second witness item, and the
/// only thing that makes the signature in the first one spendable.
final _pubkeyHex = toHex(SugarWallet.import(_wif).publicKey);

void main() {
  group('amounts are read exactly, or not at all', () {
    test('a plain decimal becomes the right number of satoshis', () {
      expect(parseSugar('1'), 100000000);
      expect(parseSugar('1.5'), 150000000);
      expect(parseSugar('0.0001'), 10000);
      expect(parseSugar('0.00000001'), 1);
      expect(parseSugar('.5'), 50000000);
      expect(parseSugar(' 2.25 '), 225000000);
    });

    test('anything that could be misread is refused rather than guessed', () {
      expect(parseSugar(''), isNull);
      expect(parseSugar('abc'), isNull);
      expect(parseSugar('1,5'), isNull, reason: 'a comma is a decimal point somewhere');
      expect(parseSugar('1e3'), isNull);
      expect(parseSugar('-1'), isNull);
      expect(parseSugar('1.234567891'), isNull, reason: 'the chain has eight places');
      expect(parseSugar('1.2.3'), isNull);
    });

    test('satoshis come back as the amount that was entered', () {
      expect(sugarFromSats(150000000), '1.5');
      expect(sugarFromSats(10000), '0.0001');
      expect(sugarFromSats(1), '0.00000001');
      expect(sugarFromSats(0), '0');
      expect(parseSugar(sugarFromSats(123456789)), 123456789);
    });
  });

  testWidgets('the screen shows what the address can spend, before anything else',
      (tester) async {
    await tester.pumpWidget(_screen(FakeChain()));
    await _settle(tester);
    expect(find.text('1 SUGAR'), findsOneWidget);
    expect(find.textContaining('1 unspent output'), findsOneWidget);
    expect(find.textContaining('network fee 1 sat/vB'), findsOneWidget);
  });

  testWidgets('reviewing shows the fee, the change and the total — and signs nothing',
      (tester) async {
    final chain = FakeChain();
    await _pumpScreen(tester, chain);

    await tester.enterText(find.byType(TextField).first, _destAddress);
    await tester.enterText(find.byType(TextField).last, '0.6');
    await _tap(tester, 'Review');

    expect(find.textContaining('0.6 SUGAR'), findsWidgets);
    expect(find.textContaining('Change back to you'), findsOneWidget);
    expect(find.textContaining('Total'), findsOneWidget);
    expect(find.text('Sign and send'), findsOneWidget);
    expect(chain.broadcasted, isEmpty, reason: 'reviewing must not touch the network');
  });

  testWidgets('signing sends the transaction embit also produced, and shows its id',
      (tester) async {
    final chain = FakeChain();
    await _pumpScreen(tester, chain);

    await tester.enterText(find.byType(TextField).first, _destAddress);
    await tester.enterText(find.byType(TextField).last, '0.6');
    await _tap(tester, 'Review');
    await _tap(tester, 'Sign and send');

    expect(chain.broadcasted, hasLength(1));
    final raw = chain.broadcasted.single;

    // Version 2, segwit marker, one input — the shape embit produced.
    expect(raw.substring(0, 14), '02000000000101',
        reason: 'version 2, segwit marker and flag, one input');
    // The input spends the coin the fake chain offered, txid reversed on the wire.
    expect(raw.substring(14, 78), _wireOrder(_utxoTxid));
    expect(raw.substring(78, 86), '00000000', reason: 'output index 0');
    // Two P2WPKH outputs: 60000000 sat to the destination, 39999859 back as change,
    // and everything else went to the fee.
    expect(raw, contains('0014${_hash160Hex(_destAddress)}'));
    expect(raw, contains('00879303'), reason: '60000000 sat, little endian');
    expect(raw, contains('73596202'), reason: '39999859 sat, little endian');
    expect(100000000 - 60000000 - 39999859, 141, reason: 'the fee on the card');
    // The witness is two items — a signature and a public key — and that key is
    // this wallet's, which is the only thing that makes the signature spendable.
    expect(raw, contains('21$_pubkeyHex'),
        reason: 'the witness ends with a 33-byte public key, and it is this wallet\'s');
    // The witness carries the signature the independent implementation produced,
    // byte for byte — the same nonce, the same DER, the same hash type. The txid
    // cannot show this: it is a hash of the transaction *without* its witness.
    expect(raw, contains('304402206ff4a03dcb149d7c26ee18f74a6a654cb688a6255192e287a8d3f3f3dba74d89022077d7a1b4a8578e497b28435aec2560e4aaaf8da73a678b5b8abf66f4b3c4d6f501'),
        reason: 'the signed bytes must be the ones embit checked, not merely a valid spend');

    // The key must not be anywhere in what leaves the phone.
    expect(raw.contains(_wif), isFalse);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('57c065cacf6e7f24684a7bb669ad6a172ce2273f569b0eb5fbd2c5f8c13a42d3'),
        findsOneWidget);
  });

  testWidgets('a legacy S… coin is spent the old way, and the card says so',
      (tester) async {
    final chain = LegacyChain();
    await _pumpScreen(tester, chain);

    expect(find.textContaining('legacy S… coin'), findsOneWidget,
        reason: 'the user should know why this one costs more to spend');

    await tester.enterText(find.byType(TextField).first, _destAddress);
    await tester.enterText(find.byType(TextField).last, '0.6');
    await _tap(tester, 'Review');
    // The fee is priced for a 148 vB legacy input, not a 68 vB segwit one:
    // 11 frame + 148 input + 31 + 31 (the destination and the change), and the
    // number shown is the size of the *signed* transaction the fee is for.
    expect(find.textContaining('221 vB signed'), findsOneWidget);
    expect(find.textContaining('0.00000221 SUGAR'), findsOneWidget);
    await _tap(tester, 'Sign and send');

    expect(chain.broadcasted, hasLength(1));
    final raw = chain.broadcasted.single;

    // No segwit marker or flag: a legacy spend is not a witness transaction.
    expect(raw.substring(0, 10), '0200000001',
        reason: 'version 2 and one input, with no 0001 marker after it');
    expect(raw.contains('0001' '02000000'), isFalse);
    // A 106-byte scriptSig: push 71 (a signature and its hash type), push 33.
    expect(raw, contains('6a47'));
    expect(raw.contains(_wif), isFalse);

    // The screen's bytes are the package's bytes for the same coins, and the
    // signature in them is a real one over the digest the old rule produces.
    final wallet = SugarWallet.import(_wif);
    const outpoint = '$_utxoTxid:0';
    final plan = SendPlan.prepare(
      available: [
        Spent(
          const Utxo(txid: _utxoTxid, vout: 0, sats: 100000000, segwit: false),
          Uint8List(0),
        ),
      ],
      amountSats: 60000000,
      toAddress: _destAddress,
      changeAddress: _ownAddress,
      feeRatePerVByte: 1,
      segwitByOutpoint: const {outpoint: false},
    );
    final signed = signAll(plan, (_) => wallet.privateKey);
    expect(raw, plan.txid.isEmpty ? raw : toHex(signed.serialize()),
        reason: 'the screen and the package agree byte for byte');
    expect(plan.txid, signed.txid);

    final scriptSig = signed.ins[0].scriptSig!;
    final sigItem = scriptSig.sublist(1, 1 + scriptSig[0]); // <sig||hashtype>
    final pubItem = scriptSig.sublist(2 + scriptSig[0]); // <pubkey>
    final digest =
        signed.sighashP2pkh(0, Transaction.p2pkhScriptCode(hash160Of(wallet.publicKey)));
    expect(
        verifyHash(
          pubItem,
          digest,
          Signature.fromDer(sigItem.sublist(0, sigItem.length - 1)),
        ),
        isTrue,
        reason: 'the signature must verify against the old-rule digest, or the chain '
            'will reject it');
  });

  testWidgets('one tap pastes the address, and says whether it looks right',
      (tester) async {
    // The clipboard is a platform channel: answered here, because reading it for
    // real in a widget test just hangs.
    String clipboard = 'here you go: $_destAddress\n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': clipboard}
          : null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final chain = FakeChain();
    await _pumpScreen(tester, chain);

    await tester.tap(find.byTooltip('Paste from clipboard'));
    await _settle(tester);
    expect(find.textContaining('Address pasted'), findsOneWidget);
    // The address was pulled out of the sentence around it.
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, _destAddress);

    // A second snackbar queues behind the first, which makes what is on screen a
    // question of animation timing. It is cleared instead, so the assertion below
    // is about the app's message and not about the messenger's queue.
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pump();

    // A paste that is not an address still fills the field, and says so — rather
    // than being silently accepted and sent somewhere.
    clipboard = 'hello';
    await tester.tap(find.byTooltip('Paste from clipboard'));
    await _settle(tester);
    expect(find.textContaining('does not look like a SUGAR address'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text, 'hello');

    await tester.enterText(find.byType(TextField).last, '0.1');
    await _tap(tester, 'Review');
    expect(chain.broadcasted, isEmpty);
    expect(find.text('Sign and send'), findsNothing);
  });

  testWidgets('a rejected transaction is reported as a rejection, with the reason',
      (tester) async {
    final chain = FakeChain(reject: 'bad-txns-inputs-missingorspent');
    await _pumpScreen(tester, chain);

    await tester.enterText(find.byType(TextField).first, _destAddress);
    await tester.enterText(find.byType(TextField).last, '0.6');
    await _tap(tester, 'Review');
    await _tap(tester, 'Sign and send');

    expect(find.text('Not sent'), findsOneWidget);
    expect(find.textContaining('already been spent'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
  });

  testWidgets('an impossible amount is refused before a fee is ever computed',
      (tester) async {
    final chain = FakeChain();
    await _pumpScreen(tester, chain);

    await tester.enterText(find.byType(TextField).first, _destAddress);
    await tester.enterText(find.byType(TextField).last, '5');
    await _tap(tester, 'Review');

    expect(find.text('Cannot build that yet'), findsOneWidget);
    expect(find.textContaining('more than this address holds'), findsOneWidget);
    expect(find.text('Sign and send'), findsNothing);
  });

  testWidgets('a nonsense destination never reaches the network', (tester) async {
    final chain = FakeChain();
    await _pumpScreen(tester, chain);

    await tester.enterText(find.byType(TextField).first, 'sugar1notanaddress');
    await tester.enterText(find.byType(TextField).last, '0.1');
    await _tap(tester, 'Review');

    expect(find.textContaining('address'), findsWidgets);
    expect(find.text('Sign and send'), findsNothing);
    expect(chain.broadcasted, isEmpty);
  });
}
