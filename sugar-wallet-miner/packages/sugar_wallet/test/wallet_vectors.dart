/// Wallet vectors. Run with the Dart SDK, no packages needed:
///
///     dart run packages/sugar_wallet/test/wallet_vectors.dart
///
/// Every expectation is a published vector or an independently derived value —
/// never something this code produced and then asserted. The BIP-173 example is
/// the important one: it is the same key and the same hash160 as our bech32
/// encoding, published by the BIP itself, so if it matches, the encoding and the
/// curve math are both right.
///
/// The cross-implementation vector is the second line of defence: the same
/// private key must produce byte-identical output in this Dart code and in the
/// JavaScript wallet of the MineHub console.
library;

// A test *script*: it prints its results as it goes, and it imports by package
// name so it runs the same way from the repo root or from the package directory.
// ignore_for_file: avoid_print

import 'dart:typed_data';

import 'package:sugar_wallet/sugar_wallet.dart';

int _pass = 0, _fail = 0;

void eq(String name, Object? got, Object? want) {
  final ok = '$got'.toLowerCase() == '$want'.toLowerCase();
  print('${ok ? '  ✓' : '  ✗'} $name');
  if (!ok) {
    print('      got  $got');
    print('      want $want');
    _fail++;
  } else {
    _pass++;
  }
}

void ok(String name, bool cond, [String note = '']) {
  print('${cond ? '  ✓' : '  ✗'} $name');
  if (!cond) {
    if (note.isNotEmpty) print('      $note');
    _fail++;
  } else {
    _pass++;
  }
}

void main() {
  print('SHA-256');
  eq('sha256("")', toHex(Sha256.digest([])),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  eq('sha256("abc")', toHex(Sha256.digest('abc'.codeUnits)),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  eq('sha256(448-bit block boundary)',
      toHex(Sha256.digest('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'.codeUnits)),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  eq('sha256(1,000,000 × "a")', toHex(Sha256.digest(List.filled(1000000, 0x61))),
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');

  print('\nRIPEMD-160');
  eq('ripemd160("")', toHex(Ripemd160.digest([])), '9c1185a5c5e9fc54612808977ee8f548b2258d31');
  eq('ripemd160("abc")', toHex(Ripemd160.digest('abc'.codeUnits)),
      '8eb208f7e05d987a9b044a8e98c6b087f15a0bfc');
  eq('ripemd160("message digest")', toHex(Ripemd160.digest('message digest'.codeUnits)),
      '5d0689ef49d2fae572b881b123a85ffa21595f36');
  eq('ripemd160(1,000,000 × "a")', toHex(Ripemd160.digest(List.filled(1000000, 0x61))),
      '52783243c1697bdbe16d37f97f68f08325dc1528');

  print('\nsecp256k1 + BIP-173 vector (private key 1)');
  final k1 = SugarWallet.fromPrivateKey(fromHex('${'0' * 63}1'));
  eq('public key is G', toHex(k1.publicKey),
      '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798');
  eq('hash160 of the public key', toHex(k1.hash160), '751e76e8199196d454941c45d1b3a323f1433bd6');
  eq('BIP-173 example re-encoded with hrp "bc"',
      bech32Encode('bc', 0, fromHex('751e76e8199196d454941c45d1b3a323f1433bd6')),
      'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');
  eq('WIF (compressed, mainnet)', k1.wif, 'KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn');
  eq('our address uses Sugarchain\'s hrp', k1.address,
      bech32Encode('sugar', 0, fromHex('751e76e8199196d454941c45d1b3a323f1433bd6')));
  ok('address is a sugar1q address the SDK accepts', looksLikeSugarAddress(k1.address),
      k1.address);

  print('\nround-trip');
  final dec = bech32Decode(k1.address)!;
  eq('decoded hrp', dec.hrp, 'sugar');
  eq('decoded program', toHex(dec.program), toHex(k1.hash160));

  print('\ncross-implementation (same key as the JavaScript wallet in MineHub)');
  // These were produced by minehub/src/sugar_wallet.js from the same keys, and
  // are asserted here so the two implementations cannot drift apart silently.
  // Produced by running minehub/src/sugar_wallet.js on the same keys — a genuine
  // cross-implementation check, not a value copied out of this file's own output.
  const crossVectors = {
    '0000000000000000000000000000000000000000000000000000000000000001': [
      'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kjjlkp2',
      'KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn',
    ],
    '0000000000000000000000000000000000000000000000000000000000000002': [
      'sugar1qq6hag67dl53wl99vzg42z8eyzfz2xlkvcvwsc7',
      'KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU74NMTptX4',
    ],
    'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef': [
      'sugar1qvmqas4maw7lg9clqu6kqu9zq9cluvlln2zcz5l',
      'L4gZxvfGxeHQYpUcvFwnuaXn8xaBKmvFTm1Z3advYg4xLJ7435BQ',
    ],
  };
  for (final entry in crossVectors.entries) {
    final w = SugarWallet.fromPrivateKey(fromHex(entry.key));
    eq('key …${entry.key.substring(56)} → same address as the JavaScript wallet',
        w.address, entry.value[0]);
    eq('key …${entry.key.substring(56)} → same WIF', w.wif, entry.value[1]);
    final back = bech32Decode(w.address);
    ok('key …${entry.key.substring(56)} → decodes back to its own hash160',
        back != null && toHex(back.program) == toHex(w.hash160));
  }

  print('\nrandom wallets');
  var good = 0;
  final rnd = _seeded();
  for (var i = 0; i < 25; i++) {
    final w = SugarWallet.generate(random: rnd);
    final checks = checkAddress(w.address);
    if (looksLikeSugarAddress(w.address) && !checks.any((c) => c.ok == false)) good++;
  }
  eq('25/25 are valid, SDK-acceptable addresses', good, 25);

  print('\ntestnet');
  final t = SugarWallet.fromPrivateKey(fromHex('${'0' * 63}1'), network: SugarNetwork.testnet);
  ok('testnet address uses tugar1q', t.address.startsWith('tugar1q'), t.address);
  eq('testnet WIF prefix', t.wif[0], 'c'); // 0xEF → 'c…'

  print('\nimport paths');
  final imported = SugarWallet.import(k1.wif);
  eq('WIF import round-trips', imported.address, k1.address);
  final fromHexKey = SugarWallet.import('${'0' * 63}1');
  eq('hex import round-trips', fromHexKey.address, k1.address);
  try {
    SugarWallet.import('not-a-key');
    ok('garbage import throws', false);
  } catch (_) {
    ok('garbage import throws', true);
  }
  try {
    SugarWallet.import(t.wif); // a testnet key taken as mainnet
    ok('wrong-network WIF is rejected', false);
  } catch (_) {
    ok('wrong-network WIF is rejected', true);
  }

  print('\naddress checks reject the wrong things');
  ok('empty string', !looksLikeSugarAddress(''));
  ok('bitcoin address', !looksLikeSugarAddress('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4'));
  ok('one character changed fails the bech32 checksum',
      bech32Decode('${k1.address.substring(0, k1.address.length - 1)}q') == null);
  ok('a valid bitcoin address decodes but is not a SUGAR network',
      bech32Decode('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4')?.hrp == 'bc');

  print('\n$_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail vector(s) failed');
}

/// A deterministic generator for the bulk test. Real wallets use
/// `Random.secure()`; this only exists so a failure is reproducible.
Uint8List Function(int) _seeded() {
  var state = BigInt.parse('0123456789abcdef' * 4, radix: 16);
  return (int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      state = (state * BigInt.from(6364136223846793005) +
              BigInt.from(1442695040888963407)) %
          BigInt.parse('1000000000000000000000000000000', radix: 16);
      out[i] = (state % BigInt.from(256)).toInt();
    }
    return out;
  };
}
