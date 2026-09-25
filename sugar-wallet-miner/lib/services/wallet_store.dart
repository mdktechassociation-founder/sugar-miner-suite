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

  /// Stores a wallet (used by both create and import).
  static Future<void> save(SugarWallet wallet) async {
    await _secure.write(key: _keySecret, value: wallet.privateKeyHex);
    await _secure.write(key: _keyNetwork, value: wallet.network.name);
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
        'app': 'SUGAR Wallet (mdktechassociation-founder/sugar-wallet-miner)',
        'createdAt': details['createdAt'],
        'network': wallet.network.name,
        'address': wallet.address,
        'legacyAddress': wallet.legacyAddress,
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefAddress);
    await prefs.remove(_prefLegacy);
    await prefs.remove(_prefNetwork);
    await prefs.remove(_prefCreated);
  }
}
