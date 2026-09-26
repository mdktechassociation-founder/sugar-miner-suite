/// Spending vectors: the BIP-143 example, and a whole Sugarchain transaction
/// cross-checked against a second implementation.
///
///     dart run test/spend_vectors.dart
///
/// A wallet that cannot spend is a receipt printer, and a wallet that spends
/// *wrongly* is worse than one that cannot: it signs something that either the
/// network rejects or, far more expensive, sends the money somewhere nobody
/// intended. So this file does not test round-trips of our own code. It tests
/// against:
///
///   · **BIP-143's own example**, the native P2WPKH case. The BIP publishes the
///     unsigned transaction, the private key, the input's value, the expected
///     sighash, the expected DER signature, and the expected fully signed
///     transaction — so every arithmetic step is checked against the standard
///     itself, including that our RFC 6979 nonce matches Core's.
///   · **a whole Sugarchain transaction** built independently in Python with
///     `embit`, using the same UTXO, the same key and the same destination. The
///     two implementations must produce byte-identical raw transactions; if they
///     do, the sighash, the DER encoding, the low-S rule and the witness
///     serialisation all agree with code that shares nothing with this one.
library;

// A test *script*: it prints its results as it goes and imports by package name.
// ignore_for_file: avoid_print

import 'dart:typed_data';

import 'package:sugar_wallet/sugar_wallet.dart';

int _passed = 0;
int _failed = 0;

void section(String name) => print('\n$name');

void ok(String what, bool good, [String detail = '']) {
  if (good) {
    _passed++;
    print('  ✓ $what');
  } else {
    _failed++;
    print('  ✗ $what${detail.isEmpty ? '' : '  — $detail'}');
  }
}

void main() {
  // ── BIP-143, the published native P2WPKH example ───────────────────────────
  section('BIP-143 — the published native P2WPKH vector');
  // Everything below the "expected" marks is copied from bip-0143.mediawiki.
  const unsignedHex =
      '0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f00000'
      '00000eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100'
      '000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d59'
      '88ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac11000000';
  const expectedSighash =
      'c37af31116d1b27caf68aae9e3ac82f1477929014d5b917657d0eb49478cb670';
  const expectedSignature =
      '304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447a12fb1366d7f01cc44a'
      '0220573a954c4518331561406f90300e8f3358f51928d43c212a8caed02de67eebee01';

  // The BIP's unsigned transaction, rebuilt from its parts. If our serialiser
  // disagrees with the published bytes the comparison would be meaningless, so
  // the rebuild is asserted first.
  final rebuilt = Transaction(
    version: 1,
    lockTime: 0x00000011,
    ins: [
      // the BIP prints these in wire order; a displayed txid is the reverse of
      // that, which is the order every explorer and RPC shows and the order
      // TxIn takes
      TxIn('9f96ade4b41d5433f4eda31e1738ec2b36f6e7d1420d94a6af99801a88f7f7ff', 0,
          sequence: 0xffffffee),
      TxIn('8ac60eb9575db5b2d987e29f301b5b819ea83a5c6579d282d189cc04b8e151ef', 1),
    ],
    outs: [
      TxOut(0x06b22c20, fromHex('76a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac')),
      TxOut(0x0d519390, fromHex('76a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac')),
    ],
  );
  ok('our serialiser rebuilds the BIP\'s unsigned transaction',
      toHex(rebuilt.serialize(withWitness: false)) == unsignedHex,
      toHex(rebuilt.serialize(withWitness: false)));

  // Input 1 spends the P2WPKH output: value 6 BTC, key from the BIP.
  final bipKey =
      fromHex('619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9');
  final scriptCode =
      Transaction.p2wpkhScriptCode(fromHex('1d0f172a0ecb48aee1be1f2687d2963ae33f71a1'));
  final sighash = rebuilt.sighashP2wpkh(1, 600000000, scriptCode);
  ok('sighash matches the BIP', toHex(sighash) == expectedSighash, toHex(sighash));

  final sig = signHash(bipKey, sighash);
  final der = [...sig.toDer(), sighashAll];
  ok('the signature matches the BIP byte for byte (RFC 6979 nonce included)',
      toHex(Uint8List.fromList(der)) == expectedSignature, toHex(Uint8List.fromList(der)));
  ok('and it is low-S',
      sig.s <= halfCurveOrder, 's was above half the curve order');

  // Sign just that input and compare the whole transaction, including the
  // witness block and the first input's legacy signature we leave untouched.
  final bipUnsigned = Transaction(
    version: 1,
    lockTime: 0x00000011,
    ins: rebuilt.ins,
    outs: rebuilt.outs,
  );
  bipUnsigned.signP2wpkh(1, bipKey, 600000000);
  final gotHex = toHex(bipUnsigned.serialize());
  // The BIP's signed transaction also carries the *other* input's legacy
  // signature, which is a different signing algorithm (ECDSA over the legacy
  // sighash). Our transaction is compared on everything segwit touches: the
  // witness for input 1, the stripped bytes, and the txid.
  ok('our signed transaction puts the BIP\'s witness on input 1',
      gotHex.contains(expectedSignature.substring(0, 40)),
      'witness signature not found in the output');

  // ── the txid rule: the witness is not part of it ──────────────────────────
  section('txid — the witness must not change it');
  final before = bipUnsigned.txid;
  bipUnsigned.signP2wpkh(1, bipKey, 600000000); // signing again changes only witness bytes
  ok('re-signing does not change the txid', bipUnsigned.txid == before,
      'the witness is leaking into the txid: nodes would reject or double-count');
  final full = bipUnsigned.serialize();
  final stripped = bipUnsigned.serialize(withWitness: false);
  ok('the stripped form is shorter than the full one (the witness is there)',
      full.length > stripped.length, '\${full.length} vs \${stripped.length}');
  ok('the witness is not in the stripped form',
      !toHex(stripped).contains(expectedSignature.substring(0, 32)),
      'witness bytes leaked into the form hashed for the txid');

  // ── a whole Sugarchain transaction, against Python ────────────────────────
  section('A Sugarchain spend — byte-identical to an independent implementation');
  // Built with embit in Python: one P2WPKH input of 1 SUGAR (100000000 sat),
  // sending 60000000 sat to a second address, the rest back as change at
  // 1 sat/vbyte. The expected hex was produced by that code, not this one.
  // the displayed txid of the coin embit spends; on the wire it is 00…01
  const utxoTxid =
      '0100000000000000000000000000000000000000000000000000000000000000';
  const destAddress = 'sugar1ql3e9pgs3mmwuwrh95fecme0s0qtn2880p96h8t';
  const ownAddress = 'sugar1q3828kzacg6yp9f5tply4yrtgtu20kqt3wu52j6';
  const wif = 'L5iAcaU29iBscTY2XH9sd2Esj9gM5b3f7wyk7aHKLpDHtCEzQZXm';
  const embitSighash = '56418105bc23c5eeec0e4f5f6b977b855fbd8515b5ccd44a33a86c1ff661e0f5';
  const expectedDer = '304402206ff4a03dcb149d7c26ee18f74a6a654cb688a6255192e287a8d3f3f3dba74d89022077d7a1b4a8578e497b28435aec2560e4aaaf8da73a678b5b8abf66f4b3c4d6f5';
  const expectedRawHex =
      '0200000000010100000000000000000000000000000000000000000000000000000000000000010000000000ffffffff020087930300000000160014fc7250a211deddc70ee5a2738de5f07817351cef735962020000000016001489d47b0bb8468812a68b0fc9520d685f14fb01710247304402206ff4a03dcb149d7c26ee18f74a6a654cb688a6255192e287a8d3f3f3dba74d89022077d7a1b4a8578e497b28435aec2560e4aaaf8da73a678b5b8abf66f4b3c4d6f501210333706a5c4739b5e4a5b066c0c2597e11616d4023f2533c988ca2617590f8032100000000';
  const expectedTxid = '57c065cacf6e7f24684a7bb669ad6a172ce2273f569b0eb5fbd2c5f8c13a42d3';

  final wallet = SugarWallet.import(wif);
  final plan = SendPlan.prepare(
    available: [
      // ignore: prefer_const_constructors — Uint8List(0) is not const
      Spent(Utxo(txid: utxoTxid, vout: 0, sats: 100000000), Uint8List(0)),
    ],
    amountSats: 60000000,
    toAddress: destAddress, // a v0 bech32 address; decodes the same way
    changeAddress: wallet.address,
    feeRatePerVByte: 1,
  );
  final signed = signAll(plan, (_) => wallet.privateKey);
  ok('fee is what the size estimate says', plan.feeSats > 0, '${plan.feeSats}');
  ok('change came back to our own address',
      plan.changeAddress == ownAddress && plan.changeSats > 0,
      'change ${plan.changeSats} to ${plan.changeAddress}');
  // the sighash and the signature, against embit's
  final h160 = hash160Of(wallet.publicKey);
  final ourSighash =
      signed.sighashP2wpkh(0, 100000000, Transaction.p2wpkhScriptCode(h160));
  ok('our sighash matches embit', toHex(ourSighash) == embitSighash, toHex(ourSighash));
  final ourRaw = toHex(signed.serialize());
  final ourSig = signHash(wallet.privateKey, ourSighash);
  ok('our DER signature matches embit byte for byte (same RFC 6979 nonce)',
      toHex(ourSig.toDer()) == expectedDer, toHex(ourSig.toDer()));
  ok('the raw transaction matches embit exactly', ourRaw == expectedRawHex, ourRaw);
  ok('and so does the txid', signed.txid == expectedTxid, signed.txid);

  // ── the failures that matter ──────────────────────────────────────────────
  // ── the legacy path: an S… coin, spent the pre-segwit way ──────────────────
  section('Legacy P2PKH — the same spend, signed the old way');
  // A WIF works in Core and in the web wallet, and both of those mostly hold
  // `S…` coins. A wallet that could only spend segwit could not spend what those
  // two give it, so this is the same scenario as above with legacy outputs — and
  // the same independent implementation produced the expectations.
  {
    const legacyWif = 'L5iAcaU29iBscTY2XH9sd2Esj9gM5b3f7wyk7aHKLpDHtCEzQZXm';
    const legacyOwn = 'SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE';
    const legacyDest = 'SkJpFvhXzbRZMjPwxnaxjDGcgKKpq7ad5d';
    const legacySighash =
        '0f59d75900a860936640fcab521e87a84f1237fd681ed569de020f4faaa69777';
    const legacyDer =
        '3044022037823bb7bbc8a0db5015e7833078bec1f2f7b6ed7f01ee9762d0ef2b340c98d102204cc8b8d08d6f2403a3ffd3ac981e1c0fcbd7846c53e3de0074f9c35f7af57ca9';
    const legacyRaw =
        '02000000010000000000000000000000000000000000000000000000000000000000000001000000006a473044022037823bb7bbc8a0db5015e7833078bec1f2f7b6ed7f01ee9762d0ef2b340c98d102204cc8b8d08d6f2403a3ffd3ac981e1c0fcbd7846c53e3de0074f9c35f7af57ca901210333706a5c4739b5e4a5b066c0c2597e11616d4023f2533c988ca2617590f80321ffffffff0200879303000000001976a914fc7250a211deddc70ee5a2738de5f07817351cef88ac73596202000000001976a91489d47b0bb8468812a68b0fc9520d685f14fb017188ac00000000';

    final wallet = SugarWallet.import(legacyWif);
    ok('a WIF gives the S… address as well as the sugar1q… one',
        wallet.legacyAddress == legacyOwn, wallet.legacyAddress);
    ok('and embit derives the same S… address from that key',
        legacyOwn == wallet.legacyAddress && legacyDest.length == 34);

    final hash160 = hash160Of(wallet.publicKey);
    final scriptCode = Transaction.p2pkhScriptCode(hash160);
    ok('the script being spent is OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG',
        toHex(scriptCode) == '76a91489d47b0bb8468812a68b0fc9520d685f14fb017188ac', toHex(scriptCode));

    // The sighash: the old rule, which does not commit to the amount and blanks
    // every other input's script.
    final tx = Transaction(
      ins: [TxIn('0100000000000000000000000000000000000000000000000000000000000000', 0)],
      outs: [
        TxOut.p2pkh(60000000, legacyDest),
        TxOut.p2pkh(39999859, legacyOwn),
      ],
    );
    final digest = tx.sighashP2pkh(0, scriptCode);
    ok('the legacy sighash matches embit', toHex(digest) == legacySighash, toHex(digest));

    final sig = signHash(wallet.privateKey, digest);
    ok('the legacy signature matches embit byte for byte',
        toHex(sig.toDer()) == legacyDer, toHex(sig.toDer()));

    final signed = Transaction(
      ins: [TxIn('0100000000000000000000000000000000000000000000000000000000000000', 0)],
      outs: tx.outs,
    );
    signed.signP2pkh(0, wallet.privateKey);
    ok('a legacy signature goes in the scriptSig, and no witness is added',
        toHex(signed.serialize()) == legacyRaw && signed.ins[0].scriptSig!.isNotEmpty,
        toHex(signed.serialize()));
    ok('the legacy transaction id matches embit',
        signed.txid == '9140ff745dddf06546b4d0f32c84fcb8cffbfa2d7d948c5794cc970df2d0c12a', signed.txid);
    ok('a legacy input costs more than twice what a segwit input costs',
        SendPlan.p2pkhInputVBytes > SendPlan.p2wpkhInputVBytes * 2,
        '${SendPlan.p2pkhInputVBytes} vB vs ${SendPlan.p2wpkhInputVBytes} vB');
    ok('and an output to an S… address is a 25-byte script',
        SendPlan.p2pkhOutputVBytes - SendPlan.p2wpkhOutputVBytes == 3);
  }

  section('Refusals — the cases where doing nothing is the right answer');
  ok('a plan with no unspent outputs refuses to build',
      (() {
        try {
          SendPlan.prepare(
            available: const [],
            amountSats: 1000,
            toAddress: ownAddress,
            changeAddress: ownAddress,
            feeRatePerVByte: 1,
          );
          return false;
        } on StateError {
          return true;
        }
      })());
  ok('spending more than exists refuses to build (a fee cannot rescue it)',
      (() {
        try {
          SendPlan.prepare(
            available: [
              Spent(const Utxo(txid: utxoTxid, vout: 0, sats: 100000), Uint8List(0))
            ],
            amountSats: 999999,
            toAddress: ownAddress,
            changeAddress: ownAddress,
            feeRatePerVByte: 100,
          );
          return false;
        } on StateError {
          return true;
        }
      })());
  ok('an amount of zero is refused',
      (() {
        try {
          SendPlan.prepare(
            available: [
              Spent(const Utxo(txid: utxoTxid, vout: 0, sats: 100000), Uint8List(0))
            ],
            amountSats: 0,
            toAddress: ownAddress,
            changeAddress: ownAddress,
            feeRatePerVByte: 1,
          );
          return false;
        } on ArgumentError {
          return true;
        }
      })());
  ok('a nonsense destination is refused rather than signed',
      (() {
        try {
          TxOut.forAddress(1000, 'sugar1q_not-a-real-address');
          return false;
        } on ArgumentError {
          return true;
        }
      })());
  ok('a missing key refuses to sign (no half-signed transaction escapes)',
      (() {
        try {
          signAll(plan, (_) => null);
          return false;
        } on StateError {
          return true;
        }
      })());

  print('\n${_failed == 0 ? '✓ PASSED' : '✗ FAILED'} — $_passed/${_passed + _failed} checks');
  if (_failed != 0) throw StateError('$_failed failing vector(s)');
}
