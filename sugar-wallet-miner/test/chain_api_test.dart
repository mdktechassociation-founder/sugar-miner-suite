// The chain service is the only part of this app that trusts a stranger. So the
// tests here are about what it does when that stranger is wrong: a fee rate in the
// wrong unit, an unspent output that is not this wallet's, a "success" that is not
// a txid, and an error that arrives inside a 200.
import 'package:flutter_test/flutter_test.dart';
import 'package:sugar_wallet_miner/services/chain_api.dart';

const _address = 'sugar1q3828kzacg6yp9f5tply4yrtgtu20kqt3wu52j6';
// The same address with a different 20-byte program, so the scripts differ.
const _otherAddress = 'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kjjlkp2';

/// A chain whose answers are handed to it, and which records what it was asked.
ChainApi _api(Map<String, String> answers, {List<String>? posted}) {
  Future<String> get(String url, {Duration timeout = Duration.zero}) async {
    for (final entry in answers.entries) {
      if (url.endsWith(entry.key)) return entry.value;
    }
    throw StateError('no canned answer for $url');
  }

  Future<String> post(String url, String body, {Duration timeout = Duration.zero}) async {
    posted?.add('$url $body');
    final answer = answers['__post'];
    if (answer == null) throw StateError('no canned answer for a POST');
    return answer;
  }

  return ChainApi(get: get, post: post);
}

void main() {
  group('the fee is converted in the right unit, every time', () {
    test('satoshis per kilobyte become satoshis per virtual byte', () {
      // The chain answers 1001 sat/kB today: a fractionally rounded 1 sat/vB.
      // Rounding it up would double every fee this wallet pays.
      expect(ChainApi.vByteRateFromPerKb(1001), 1);
      expect(ChainApi.vByteRateFromPerKb(1000), 1);
      expect(ChainApi.vByteRateFromPerKb(1500), 2);
      expect(ChainApi.vByteRateFromPerKb(2000), 2);
      expect(ChainApi.vByteRateFromPerKb(25000), 25);
    });

    test('a nonsense rate becomes the floor, not a free transaction', () {
      expect(ChainApi.vByteRateFromPerKb(0), kMinFeeRatePerVByte);
      expect(ChainApi.vByteRateFromPerKb(-1), kMinFeeRatePerVByte);
      expect(ChainApi.vByteRateFromPerKb(1), kMinFeeRatePerVByte);
    });

    test('a wildly wrong rate is capped rather than obeyed', () {
      expect(ChainApi.vByteRateFromPerKb(3000000), kMaxFeeRatePerVByte);
    });

    test('the live answer is read out of the envelope the API actually uses', () async {
      final api = _api({
        '/fee': '{"error":null,"id":"api-server","result":{"blocks":6,"feerate":1001}}',
      });
      expect(await api.feeRatePerVByte(), 1);
    });

    test('an error inside a 200 is an error, not a zero', () async {
      final api = _api({'/fee': '{"error":{"code":-1,"message":"no estimator"},"result":null}'});
      await expectLater(api.feeRatePerVByte(), throwsA(isA<FormatException>()));
    });
  });

  group('only coins that belong to this wallet are offered as spendable', () {
    test('P2WPKH for the address asked about is kept', () async {
      final api = _api({
        '/unspent/$_address': '{"error":null,"result":['
            '{"txid":"ab${'0' * 62}","index":0,"script":"'
            '${ChainApi.scriptForAddress(_address)!.segwitScript}","value":5000,"height":1}]}',
      });
      final utxos = await api.unspent(_address);
      expect(utxos, hasLength(1));
      expect(utxos.single.sats, 5000);
    });

    test('a coin for somebody else is dropped, however the node labels it', () async {
      final api = _api({
        '/unspent/$_address': '{"error":null,"result":['
            '{"txid":"ab${'0' * 62}","index":0,"script":"'
            '${ChainApi.scriptForAddress(_otherAddress)!.segwitScript}","value":5000,"height":1},'
            '{"txid":"cd${'0' * 62}","index":1,"script":"'
            '${ChainApi.scriptForAddress(_otherAddress)!.segwitScript}","value":900000,"height":2}]}',
      });
      expect(await api.unspent(_address), isEmpty,
          reason: 'signing coins that are not yours is the one thing a wallet must not do');
    });

    test('a row that is not a coin at all is skipped, not crashed on', () async {
      final api = _api({
        '/unspent/$_address': '{"error":null,"result":['
            '{"txid":42,"index":"0","value":"lots"},'
            '{"txid":"cd${'0' * 62}","index":1,"value":900000,"height":2}]}',
      });
      final utxos = await api.unspent(_address);
      expect(utxos, hasLength(1), reason: 'the row without a script is kept: it is truncated, not foreign');
      expect(utxos.single.sats, 900000);
    });

    test('the biggest coin comes first, so the fewest coins are spent', () async {
      String row(String hex, int sats) => '{"txid":"$hex${'0' * 62}","index":0,"value":$sats}';
      final api = _api({
        '/unspent/$_address': '{"error":null,"result":['
            '${row('aa', 1000)},${row('bb', 900000)},${row('cc', 40000)}]}',
      });
      final utxos = await api.unspent(_address);
      expect([for (final u in utxos) u.sats], [900000, 40000, 1000]);
    });

    test('an address that is not ours to spend has no script to check against', () {
      expect(ChainApi.scriptForAddress('sugar1qnot-a-real-address'), isNull);
      expect(ChainApi.scriptForAddress('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4'), isNotNull,
          reason: 'a valid bech32 string does have a script; the network it is for is a separate matter');
    });

    test('a sugar1q… address has one script: OP_0 and the 20-byte hash', () {
      final scripts = ChainApi.scriptForAddress(_address)!;
      expect(scripts.segwitScript, startsWith('0014'));
      expect(scripts.segwitScript!.length, 44);
      expect(scripts.legacyScript, isNull);
    });

    test('an S… address has the other one: OP_DUP OP_HASH160 … CHECKSIG', () {
      final scripts =
          ChainApi.scriptForAddress('SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE')!;
      expect(scripts.legacyScript, startsWith('76a914'));
      expect(scripts.legacyScript, endsWith('88ac'));
      expect(scripts.legacyScript!.length, 50);
      expect(scripts.segwitScript, isNull);
    });

    test('a legacy coin comes back marked as legacy, so it is signed the old way', () async {
      final legacy = ChainApi.scriptForAddress('SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE')!.legacyScript;
      final api = _api({
        '/unspent/SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE':
            '{"error":null,"result":['
            '{"txid":"ab${'0' * 62}","index":0,"script":"$legacy","value":5000,"height":1}]}',
      });
      final utxos = await api.unspent('SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE');
      expect(utxos, hasLength(1));
      expect(utxos.single.segwit, isFalse,
          reason: 'signing a legacy coin with BIP-143 produces a signature no node accepts');
    });

    test('a segwit coin is marked as segwit', () async {
      final api = _api({
        '/unspent/$_address': '{"error":null,"result":['
            '{"txid":"ab${'0' * 62}","index":0,"script":"'
            '${ChainApi.scriptForAddress(_address)!.segwitScript}","value":5000}]}',
      });
      expect((await api.unspent(_address)).single.segwit, isTrue);
    });
  });

  group('a broadcast is only a success when the node says so', () {
    const txid = '57c065cacf6e7f24684a7bb669ad6a172ce2273f569b0eb5fbd2c5f8c13a42d3';

    test('a txid is accepted, and lower-cased', () async {
      final posted = <String>[];
      final api = _api({'__post': txid.toUpperCase()}, posted: posted);
      expect(await api.broadcast('02000000'), txid);
      expect(posted.single, startsWith('https://api.sugar.wtf/esplora/tx 02000000'),
          reason: 'the one write goes to the endpoint the chain itself publishes');
    });

    test('the complaint from the node is passed through, not paraphrased', () async {
      final api = _api({'__post': 'bad-txns-inputs-missingorspent'});
      await expectLater(
        api.broadcast('02000000'),
        throwsA(predicate((e) => '$e'.contains('missingorspent'))),
      );
    });

    test('an empty answer is not a txid', () async {
      final api = _api({'__post': '  '});
      await expectLater(api.broadcast('02000000'), throwsA(isA<FormatException>()));
    });

    test('something that is not a txid is not a success', () async {
      final api = _api({'__post': 'ok'});
      await expectLater(api.broadcast('02000000'), throwsA(isA<FormatException>()));
    });

    test('nothing is posted when there is nothing to post', () async {
      final posted = <String>[];
      final api = _api({'__post': txid}, posted: posted);
      await expectLater(api.broadcast('   '), throwsA(isA<FormatException>()));
      expect(posted, isEmpty);
    });
  });
}
