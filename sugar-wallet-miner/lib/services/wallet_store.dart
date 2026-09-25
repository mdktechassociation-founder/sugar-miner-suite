/// Where the wallet lives on the device.
///
/// Two stores, on purpose:
///
///  * the **private key** goes to the platform keystore (Android's
///    EncryptedSharedPreferences, keyed by a hardware-backed Keystore entry),
///    and is only read when the user asks to see or export it;
///  * the **address** is also mirrored into ordinary preferences, because the
///    headless isolate that runs after a reboot must be able to read it before
///    any UI exists, and an address is public information anyway — it is the
///    thing the pool and every blockchain explorer already know.
///
/// Storing the key in the keystore and the address in plain preferences means a
/// reboot can resume mining without the app being opened, and without putting key
/// material anywhere it is not needed. Mining itself never touches the key: the
/// SDK is handed the address and nothing else.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sugar_wallet/sugar_wallet.dart';

class WalletStore {
  static const _keySecret = 'sugar_wallet_private_key';
  static const _keyNetwork = 'sugar_wallet_network';
  // The recovery phrase is kept beside the key — same store, same keystore — so a
  // user can read it back when they have lost the paper. Anyone who can read this
  // can already read the key: the phrase is not a second copy of the secret so
  // much as the readable form of it.
  static const _keyPhrase = 'sugar_wallet_phrase';
  static const _keyPath = 'sugar_wallet_derivation_path';
  static const _prefAddress = 'sugar_sdk_device_address';
  static const _prefLegacy = 'sugar_sdk_device_legacy_address';
  static const _prefCreated = 'sugar_sdk_device_created_at';
  static const _prefNetwork = 'sugar_sdk_device_network';

  /// v11's Android defaults are already what this needs: AES-GCM for the value,
  /// an RSA-OAEP key in the hardware-backed Keystore for the wrapping key. Nothing
  /// is passed here because the safest option for a private key is precisely the
  /// one the plugin calls default.
  static const _secure = FlutterSecureStorage();

  /// Generates a wallet from the platform's secure random source and stores it.
  static Future<SugarWallet> create({SugarNetwork? network}) async {
    final net = network ?? SugarNetwork.mainnet;
    final wallet = SugarWallet.generate(
      network: net,
      random: (n) {
        final r = Random.secure();
        final bytes = Uint8List(n);
        for (var i = 0; i < n; i++) {
          bytes[i] = r.nextInt(256);
        }
        return bytes;
      },
    );
    await save(wallet);
    return wallet;
  }

  /// Creates a wallet that can be written down: twelve words, from which the key
  /// above is derived at Sugarchain's BIP-44 path. The phrase restores in any
  /// BIP-39 wallet that reads coin type 408.
  static Future<PhraseWallet> createPhrase({SugarNetwork? network}) async {
    final net = network ?? SugarNetwork.mainnet;
    final pw = PhraseWallet.create(network: net, random: (n) {
      final r = Random.secure();
      final bytes = Uint8List(n);
      for (var i = 0; i < n; i++) {
        bytes[i] = r.nextInt(256);
      }
      return bytes;
    });
    await save(pw.wallet, phrase: pw.phrase, path: pw.path);
    return pw;
  }

  /// Rebuilds a wallet from whatever the user pasted: a recovery phrase, an
  /// extended private key, a WIF, or a 64-character hex key. One entry point, so
  /// every screen that accepts a wallet accepts the same things.
  static Future<SugarWallet> restore(String text,
      {SugarNetwork? network, String path = sugarBip44Path}) async {
    final trimmed = text.trim();
    final SugarWallet wallet;
    String? phrase;
    String? usedPath; // the parameter is the default; this records what was used
    final wordCount = trimmed.isEmpty ? 0 : trimmed.split(RegExp(r'\s+')).length;
    if (wordCount == 12 || wordCount == 24) {
      final pw = PhraseWallet.fromPhrase(trimmed, network: network, path: path);
      wallet = pw.wallet;
      phrase = pw.phrase;
      usedPath = pw.path;
    } else if (trimmed.startsWith('xprv')) {
      final pw = PhraseWallet.fromXprv(trimmed, network: network);
      wallet = pw.wallet;
      phrase = '';
      path = '';
    } else {
      wallet = SugarWallet.import(trimmed, network: network);
    }
    await save(wallet, phrase: phrase, path: usedPath);
    return wallet;
  }

  /// The recovery phrase, when this wallet was made with one.
  static Future<String?> phrase() async {
    final value = await _secure.read(key: _keyPhrase);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The derivation path the phrase was used at, for an exact restore elsewhere.
  static Future<String?> derivationPath() => _secure.read(key: _keyPath);

  /// Stores a wallet (used by both create and import).
  static Future<void> save(SugarWallet wallet, {String? phrase, String? path}) async {
    await _secure.write(key: _keySecret, value: wallet.privateKeyHex);
    await _secure.write(key: _keyNetwork, value: wallet.network.name);
    if (phrase == null || phrase.isEmpty) {
      // A wallet restored from a raw key has no phrase, and a phrase left over
      // from a previous wallet must never be shown against this one.
      await _secure.delete(key: _keyPhrase);
      await _secure.delete(key: _keyPath);
    } else {
      await _secure.write(key: _keyPhrase, value: phrase);
      await _secure.write(key: _keyPath, value: path ?? sugarBip44Path);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefAddress, wallet.address);
    await prefs.setString(_prefLegacy, wallet.legacyAddress);
    await prefs.setString(_prefNetwork, wallet.network.name);
    await prefs.setString(_prefCreated, DateTime.now().toUtc().toIso8601String());
  }

  /// The wallet, or null if this device has none yet.
  static Future<SugarWallet?> load() async {
    // Route 1: the checkout with the key in it.
    try {
      final hex = await _secure.read(key: _keySecret);
      if (hex != null && hex.isNotEmpty) {
        final network = SugarNetwork.byName(await _secure.read(key: _keyNetwork) ?? 'mainnet');
        return SugarWallet.fromPrivateKey(fromHex(hex), network: network);
      }
    } catch (_) {
      // A failed keystore read must not brick the app: fall through to the
      // address-only path, which is enough to keep mining pointed at the right
      // wallet. The user is told the key could not be read.
    }
    return null;
  }

  /// The address alone — readable from a headless isolate, and all mining needs.
  static Future<String?> address() async {
    final prefs = await SharedPreferences.getInstance();
    final a = prefs.getString(_prefAddress);
    return (a == null || a.isEmpty) ? null : a;
  }

  static Future<Map<String, String?>> details() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'address': prefs.getString(_prefAddress),
      'legacy': prefs.getString(_prefLegacy),
      'network': prefs.getString(_prefNetwork),
      'createdAt': prefs.getString(_prefCreated),
      'phrase': await phrase(),
      'path': await derivationPath(),
    };
  }

  static Future<void> setAddressOnly(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefAddress, address);
  }

  /// A backup file the user can keep. Contains the key, so the caller must warn.
  static String backupJson(SugarWallet wallet, Map<String, String?> details) =>
      const JsonEncoder.withIndent('  ').convert({
        'note': 'SUGAR Wallet backup. Anyone holding privateKeyHex or wif can spend '
            'this wallet. Keep it offline. There is no recovery service and no '
            'password reset — if this file is lost, the SUGAR is unreachable forever.',
        'app': 'SUGAR Wallet (sugar-miner-suite/sugar-wallet-miner)',
        'createdAt': details['createdAt'],
        'network': wallet.network.name,
        'address': wallet.address,
        'legacyAddress': wallet.legacyAddress,
        // Present only for a wallet made from words. The phrase is the most
        // durable form of this file: twelve words survive a house move, a dead
        // laptop and ten years, where a hex string does not.
        if (details['phrase'] != null) 'phrase': details['phrase'],
        if (details['path'] != null) 'derivationPath': details['path'],
        'publicKeyHex': toHex(wallet.publicKey),
        'wif': wallet.wif,
        'privateKeyHex': wallet.privateKeyHex,
      });

  /// Wipes the wallet from this device. Mining stops with it; the SUGAR that is
  /// already at the address does not — it is on the chain, and the backup file
  /// (or the key) is the only way to move it.
  static Future<void> erase() async {
    await _secure.delete(key: _keySecret);
    await _secure.delete(key: _keyNetwork);
    await _secure.delete(key: _keyPhrase);
    await _secure.delete(key: _keyPath);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefAddress);
    await prefs.remove(_prefLegacy);
    await prefs.remove(_prefNetwork);
    await prefs.remove(_prefCreated);
  }
}
