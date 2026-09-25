/// Phrase-wallet vectors: SHA-512, HMAC, PBKDF2, BIP-39, BIP-32, and Sugarchain
/// end to end.
///
///     dart run test/hd_vectors.dart
///
/// Every expectation here comes from somewhere other than this code:
///
///   · SHA-512       — NIST's published digests, and boundary cases (111, 128,
///                     1000 bytes) computed with Python's hashlib
///   · HMAC-SHA512   — RFC 4231's four published cases
///   · BIP-39        — the reference vector set (trezor/python-mnemonic), whose
///                     seeds are computed with the passphrase "TREZOR"
///   · BIP-32        — test vector 1, printed in the BIP itself, six chains deep
///   · Sugarchain    — one phrase derived to m/44'/408'/0'/0/0 and encoded with
///                     chainparams values (hrp "sugar", p2pkh 0x3f, wif 0x80) by
///                     `bip-utils`, a Python library this project does not
///                     otherwise use
///
/// The last one is the composed claim — "our twelve words make this address" —
/// and it is checked against a second implementation rather than against
/// ourselves.
library;

// A test *script*: it prints its results as it goes and imports by package name.
// ignore_for_file: avoid_print

import 'dart:convert';
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

List<int> _rep(int byte, int count) => List<int>.filled(count, byte);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // ── SHA-512 ────────────────────────────────────────────────────────────────
  section('SHA-512 — NIST digests, and the padding boundaries');
  final shaCases = <List<int>, String>{
    <int>[]: 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce'
        '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e',
    utf8.encode('abc'): 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
        '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
    _rep(0xab, 111): '725eabf1a0fc997b6aeb270b58b444a40db059c5dffd16997bd4450ab73ebad7'
        '0aff768b73920635dea83bccc014cd20eba02892ecd7be1d1ea5b29eb078a3bd',
    _rep(0xab, 128): 'eb1e622bef9b054af09d1ebe393236ba511fffdcc1e861fee42916e1bc173051'
        '6403ed2126e472b714835b784e6f1a13e4675fb0c645c865e81c6fdc68eb64af',
    _rep(0x61, 1000): '67ba5535a46e3f86dbfbed8cbbaf0125c76ed549ff8b0b9e03e0c88cf90fa63'
        '4fa7b12b47d77b694de488ace8d9a65967dc96df599727d3292a8d9d447709c97',
  };
  shaCases.forEach((msg, want) {
    final got = _hex(Sha512.digest(msg));
    ok('sha512(${msg.isEmpty ? 'empty' : '${msg.length} bytes'})', got == want,
        got == want ? '' : 'got ${got.substring(0, 32)}… want ${want.substring(0, 32)}…');
  });

  // ── HMAC-SHA512 ────────────────────────────────────────────────────────────
  section('HMAC-SHA512 — RFC 4231, all four cases');
  final hmacCases = <List<List<int>>, String>{
    [_rep(0x0b, 20), utf8.encode('Hi There')]:
        '87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde'
        'daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854',
    [utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?')]:
        '164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554'
        '9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737',
    [_rep(0xaa, 20), _rep(0xdd, 50)]:
        'fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39'
        'bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb',
    [
      List<int>.generate(25, (i) => i + 1),
      _rep(0xcd, 50)
    ]:
        'b0ba465637458c6990e5a8c5f61d4af7e576d97ff94b872de76f8050361ee3db'
        'a91ca5c11aa25eb4d679275cc5788063a5f19741120c4f2de2adebeb10a298dd',
  };
  hmacCases.forEach((pair, want) {
    final got = _hex(HmacSha512.mac(pair[0], pair[1]));
    ok('hmac(${pair[0].length}-byte key, ${pair[1].length}-byte message)',
        got == want, got == want ? '' : 'got ${got.substring(0, 24)}…');
  });

  // ── BIP-39 ─────────────────────────────────────────────────────────────────
  section('BIP-39 — the reference vectors (passphrase "TREZOR")');
  final mnemonicVectors = <List<String>>[
    [
      '00000000000000000000000000000000',
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
      'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04'
    ],
    [
      '7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f',
      'legal winner thank year wave sausage worth useful legal winner thank yellow',
      '2e8905819b8723fe2c1d161860e5ee1830318dbf49a83bd451cfb8440c28bd6fa457fe1296106559a3c80937a1c1069be3a3a5bd381ee6260e8d9739fce1f607'
    ],
    [
      '80808080808080808080808080808080',
      'letter advice cage absurd amount doctor acoustic avoid letter advice cage above',
      'd71de856f81a8acc65e6fc851a38d4d7ec216fd0796d0a6827a3ad6ed5511a30fa280f12eb2e47ed2ac03b5c462a0358d18d69fe4f985ec81778c1b370b652a8'
    ],
    [
      'ffffffffffffffffffffffffffffffff',
      'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong',
      'ac27495480225222079d7be181583751e86f571027b0497b5b5d11218e0a8a13332572917f0f8e5a589620c6f15b11c61dee327651a14c34e18231052e48c069'
    ],
  ];
  for (final vec in mnemonicVectors) {
    final entropy = fromHex(vec[0]);
    final phrase = Mnemonic.fromEntropy(entropy);
    ok('entropy ${vec[0].substring(0, 8)}… → the published words', phrase == vec[1],
        phrase == vec[1] ? '' : phrase);
    ok('  …and the published seed, with passphrase "TREZOR"',
        _hex(Mnemonic.seedOf(vec[1], passphrase: 'TREZOR')) == vec[2]);
    ok('  …and the words read back to the same entropy',
        _hex(Mnemonic.entropyOf(vec[1])!) == vec[0]);
  }
  // A 24-word phrase, and the checksum doing its job.
  final long = Mnemonic.fromEntropy(fromHex('00' * 32));
  ok('24 words from 32 bytes of entropy', long.split(' ').length == 24, long);
  ok('a swapped word is caught by the checksum',
      !Mnemonic.isValid('legal winner thank year wave sausage worth useful legal winner thank legal'),
      'the last word was changed and the phrase still validated');
  ok('a word that is not in the list is caught',
      !Mnemonic.isValid('legal winner thank year wave sausage worth useful legal winner thank zebra'));
  ok('a short phrase is refused',
      !Mnemonic.isValid('legal winner thank year wave sausage worth useful legal winner'));
  ok('extra whitespace and case are tolerated',
      Mnemonic.isValid('  Legal  WINNER thank year wave sausage worth useful legal winner thank yellow '));

  // ── BIP-32 ─────────────────────────────────────────────────────────────────
  section('BIP-32 — test vector 1 from the BIP, six chains deep');
  final seed = fromHex('000102030405060708090a0b0c0d0e0f');
  final chains = <List<String>>[
    [
      'm',
      'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi',
      'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8'
    ],
    [
      "m/0'",
      'xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7',
      'xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw'
    ],
    [
      "m/0'/1",
      'xprv9wTYmMFdV23N2TdNG573QoEsfRrWKQgWeibmLntzniatZvR9BmLnvSxqu53Kw1UmYPxLgboyZQaXwTCg8MSY3H2EU4pWcQDnRnrVA1xe8fs',
      'xpub6ASuArnXKPbfEwhqN6e3mwBcDTgzisQN1wXN9BJcM47sSikHjJf3UFHKkNAWbWMiGj7Wf5uMash7SyYq527Hqck2AxYysAA7xmALppuCkwQ'
    ],
    [
      "m/0'/1/2'",
      'xprv9z4pot5VBttmtdRTWfWQmoH1taj2axGVzFqSb8C9xaxKymcFzXBDptWmT7FwuEzG3ryjH4ktypQSAewRiNMjANTtpgP4mLTj34bhnZX7UiM',
      'xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5'
    ],
    [
      "m/0'/1/2'/2",
      'xprvA2JDeKCSNNZky6uBCviVfJSKyQ1mDYahRjijr5idH2WwLsEd4Hsb2Tyh8RfQMuPh7f7RtyzTtdrbdqqsunu5Mm3wDvUAKRHSC34sJ7in334',
      'xpub6FHa3pjLCk84BayeJxFW2SP4XRrFd1JYnxeLeU8EqN3vDfZmbqBqaGJAyiLjTAwm6ZLRQUMv1ZACTj37sR62cfN7fe5JnJ7dh8zL4fiyLHV'
    ],
    [
      "m/0'/1/2'/2/1000000000",
      'xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76',
      'xpub6H1LXWLaKsWFhvm6RVpEL9P4KfRZSW7abD2ttkWP3SSQvnyA8FSVqNTEcYFgJS2UaFcxupHiYkro49S8yGasTvXEYBVPamhGW6cFJodrTHy'
    ],
  ];
  for (final chain in chains) {
    final node = ExtKey.master(seed).derive(chain[0]);
    ok('${chain[0]} → the published xprv', node.toXprv() == chain[1]);
    ok('${chain[0]} → the published xpub', node.toXpub() == chain[2]);
  }
  ok('the master key fingerprints itself correctly',
      _hex(ExtKey.master(seed).fingerprint) == '3442193e',
      _hex(ExtKey.master(seed).fingerprint));
  ok('an xprv reads back to the same key',
      ExtKey.fromXprv(chains[1][1]).toXprv() == chains[1][1]);
  ok('an xpub is refused as a wallet (watch-only)',
      (() {
        try {
          ExtKey.fromXprv(chains[1][2]);
          return false;
        } on FormatException {
          return true;
        }
      })());

  // ── Sugarchain, end to end ─────────────────────────────────────────────────
  section("Sugarchain — one phrase to m/44'/408'/0'/0/0, cross-checked with bip-utils");
  const phrase =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  final pw = PhraseWallet.fromPhrase(phrase);
  ok('seed matches bip-utils',
      _hex(Mnemonic.seedOf(phrase)) ==
          '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1'
              '9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4');
  ok('path is the Sugarchain BIP-44 path', pw.path == "m/44'/408'/0'/0/0", pw.path);
  ok('private key matches bip-utils',
      pw.wallet.privateKeyHex ==
          'fd567d9b2f97c5cf42cf4b673432ad375cbc8cf60ce9affcce97dc62ee1b465c',
      pw.wallet.privateKeyHex);
  ok('WIF matches bip-utils (imports into Core and the web wallet)',
      pw.wallet.wif == 'L5iAcaU29iBscTY2XH9sd2Esj9gM5b3f7wyk7aHKLpDHtCEzQZXm', pw.wallet.wif);
  ok('bech32 address matches bip-utils',
      pw.wallet.address == 'sugar1q3828kzacg6yp9f5tply4yrtgtu20kqt3wu52j6',
      pw.wallet.address);
  ok('legacy address matches bip-utils',
      pw.wallet.legacyAddress == 'SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE', pw.wallet.legacyAddress);
  ok('xprv matches bip-utils',
      pw.xprv ==
          'xprvA3DyG1cn3Q1o6h73PrdNkhT2uSwcUCytc61C8sk4Uie8VbTSZug7HRBnY3tzXX674GYF1WB66SZCUGuvufsTgdzbhL8VSFWuZJ8AH4RGmjP');
  ok('xpub matches bip-utils',
      pw.xpub ==
          'xpub6GDKfX9fsma6KBBWVtAP7qPmTUn6sfhjyJvnwG9g34B7NPnb7SzMqDWGPKLauvmB2Qsc4z6NCQ8mUcru4uDt85JxuEqdzVs6ZD14XjGpLLj');

  // ── the same words, two wallets ───────────────────────────────────────────
  section("The official Android wallet's path — same words, a different wallet");
  // Read out of the released APK (that repository publishes no source):
  //   function _(t, n = "m/44'/0'/0'/0", …) { bip39.mnemonicToSeed(t) … }
  // Coin type 0, Bitcoin's. Values below from bip-utils at that path.
  final official = PhraseWallet.fromPhrase(phrase, path: sugarOfficialMobilePath);
  ok('path constant is the one the official wallet uses',
      sugarOfficialMobilePath == "m/44'/0'/0'/0/0", sugarOfficialMobilePath);
  ok('WIF matches bip-utils at coin type 0',
      official.wallet.wif == 'L4p2b9VAf8k5aUahF1JCJUzZkgNEAqLfq8DDdQiyAprQAKSbu8hf',
      official.wallet.wif);
  ok('bech32 address matches bip-utils at coin type 0',
      official.wallet.address == 'sugar1qmxrw6qdh5g3ztfcwm0et5l8mvws4eva2trdxdy',
      official.wallet.address);
  ok('legacy address matches bip-utils at coin type 0',
      official.wallet.legacyAddress == 'Sh8BJH74FTAk17aCVt4upZy3XJYyPXQU3p',
      official.wallet.legacyAddress);
  ok('and it is genuinely a different wallet from the 408 one',
      official.wallet.address != pw.wallet.address && official.wallet.wif != pw.wallet.wif,
      'both paths produced the same key — the whole point of the distinction');

  // ── round trips ────────────────────────────────────────────────────────────
  section('Round trips — what a restore actually does');
  final created = PhraseWallet.create(random: (n) => Uint8List.fromList(
      List<int>.generate(n, (i) => (i * 37 + 11) & 0xff)));
  ok('a created wallet has 12 valid words', Mnemonic.isValid(created.phrase));
  final restored = PhraseWallet.fromPhrase(created.phrase);
  ok('the phrase restores the same address',
      restored.wallet.address == created.wallet.address);
  ok('the phrase restores the same WIF', restored.wallet.wif == created.wallet.wif);
  ok('importing that WIF by hand gives the same address',
      SugarWallet.import(created.wallet.wif).address == created.wallet.address);
  final fromXprv = PhraseWallet.fromXprv(created.xprv);
  ok('the xprv restores the same address',
      fromXprv.wallet.address == created.wallet.address);
  ok('a phrase with a mistyped word is refused, not silently accepted',
      (() {
        try {
          PhraseWallet.fromPhrase(
              '${created.phrase.split(' ').sublist(0, 11).join(' ')} zoo');
          return false;
        } on FormatException {
          return true;
        }
      })());
  ok('a non-ASCII passphrase is refused rather than mis-deriving',
      (() {
        try {
          Mnemonic.seedOf(created.phrase, passphrase: 'pässphrase');
          return false;
        } on FormatException {
          return true;
        }
      })());

  print('\n${_failed == 0 ? '✓ PASSED' : '✗ FAILED'} — $_passed/${_passed + _failed} checks');
  if (_failed != 0) throw StateError('$_failed failing vector(s)');
}
