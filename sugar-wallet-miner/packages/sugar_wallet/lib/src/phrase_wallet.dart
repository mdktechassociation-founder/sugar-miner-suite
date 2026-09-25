/// A wallet you can write down.
///
/// This is the piece that makes the app self-sufficient: a phrase generated here,
/// on the device, restores the same wallet in any BIP-39 wallet that reads
/// Sugarchain's coin type — and the WIF this wallet also carries imports directly
/// into Sugarchain Core (`importprivkey`) and into the web wallet. No server, no
/// sign-up, nothing sent anywhere.
library;

import 'dart:typed_data';

import 'bip32.dart';
import 'bip39.dart';
import 'sugar_wallet.dart';

class PhraseWallet {
  /// The twelve (or twenty-four) words. This *is* the wallet.
  final String phrase;

  /// The derivation path the address came from, so a restore elsewhere is exact.
  final String path;

  final SugarWallet wallet;
  final String xprv;
  final String xpub;

  PhraseWallet._({
    required this.phrase,
    required this.path,
    required this.wallet,
    required this.xprv,
    required this.xpub,
  });

  /// Creates a new wallet from the platform's secure random source.
  ///
  /// [random] must be cryptographically secure — the app passes `Random.secure()`.
  /// A phrase from a predictable source is not a wallet, it is a donation.
  factory PhraseWallet.create({
    SugarNetwork? network,
    required Uint8List Function(int) random,
    int strength = Mnemonic.strength12,
  }) {
    return PhraseWallet.fromPhrase(
      Mnemonic.generate(random: random, strength: strength),
      network: network,
    );
  }

  /// Rebuilds a wallet from words, which is what a restore — or a new phone — does.
  factory PhraseWallet.fromPhrase(
    String phrase, {
    SugarNetwork? network,
    String path = sugarBip44Path,
    String passphrase = '',
  }) {
    final net = network ?? SugarNetwork.mainnet;
    final normalised = Mnemonic.normalise(phrase);
    if (!Mnemonic.isValid(normalised)) {
      throw const FormatException(
          'that phrase is not valid — check the words and their order');
    }
    final seed = Mnemonic.seedOf(normalised, passphrase: passphrase);
    final node = ExtKey.master(seed).derive(path);
    final wallet = SugarWallet.fromPrivateKey(node.key, network: net);
    return PhraseWallet._(
      phrase: normalised,
      path: path,
      wallet: wallet,
      xprv: node.toXprv(network: net),
      xpub: node.toXpub(network: net),
    );
  }

  /// Rebuilds from an extended private key instead of words — the form the
  /// Sugarchain web wallet's BIP-32 tab accepts.
  factory PhraseWallet.fromXprv(String xprv, {SugarNetwork? network}) {
    final net = network ?? SugarNetwork.mainnet;
    final node = ExtKey.fromXprv(xprv, network: net);
    return PhraseWallet._(
      phrase: '',
      path: '',
      wallet: SugarWallet.fromPrivateKey(node.key, network: net),
      xprv: node.toXprv(network: net),
      xpub: node.toXpub(network: net),
    );
  }

  /// The words grouped for reading aloud or writing on paper, four to a line.
  String get phraseLines {
    final parts = phrase.split(' ');
    final out = <String>[];
    for (var i = 0; i < parts.length; i += 4) {
      final group = parts.skip(i).take(4).toList();
      out.add(group.asMap().entries.map((e) => '${i + e.key + 1}. ${e.value}').join('   '));
    }
    return out.join('\n');
  }
}
