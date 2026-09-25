/// SUGAR Wallet — every user gets their own Sugarchain wallet, and their phone
/// mines SUGAR into it.
///
/// The app's whole job is the parts a library cannot do: create and keep the
/// wallet, tell the user the truth on a consent screen, and show what has been
/// earned. The mining engine, its foreground service, its notification and its
/// reboot receiver all come from `sugar_miner_sdk`.
///
/// Two things in here are easy to get wrong and are called out where they happen:
/// the `@pragma('vm:entry-point')` on the boot callback, and the fact that the
/// headless path must read the address from ordinary preferences rather than from
/// the keystore (an address is public; a keystore read has no business happening
/// before the user has even unlocked the phone).
library;

import 'package:flutter/material.dart';
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';
import 'package:sugar_wallet/sugar_wallet.dart';

import 'app_config.dart';
import 'screens/home.dart';
import 'screens/onboarding.dart';
import 'screens/wallet_screen.dart';
import 'services/wallet_store.dart';
import 'theme.dart';

/// Android calls this after a reboot, an app update, or when the service is
/// re-armed — with no activity and no UI.
///
/// It is async on purpose: the first thing it does is read this device's address,
/// which is the only configuration mining needs. If there is no wallet, it mines
/// nothing and returns. It never runs the user's UI, and it never runs the
/// onboarding flow: a phone that reboots must not pop a wallet-creation screen at
/// someone who is not looking at it.
@pragma('vm:entry-point')
Future<void> sugarWalletHeadless() async {
  WidgetsFlutterBinding.ensureInitialized();
  final address = await WalletStore.address();
  if (address == null || address.isEmpty || !looksLikeSugarAddress(address)) {
    // No wallet (or an unusable one) means no mining. Failing quietly is right:
    // there is nobody to tell at this hour, and the app will explain itself the
    // next time it is opened.
    return;
  }
  await SugarMinerSdk.install(
    config: AppConfig.forAddress(address),
    policy: AppConfig.policy,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Registering the reboot hook is what makes "resumes after a restart" true.
  // The @pragma on the function above is not optional: without it, release builds
  // tree-shake the callback away and this returns false.
  final registered = await SugarMinerSdk.registerHeadlessEntrypoint(sugarWalletHeadless);
  assert(registered, 'the headless entrypoint was not registered');

  final wallet = await WalletStore.load();
  final address = wallet?.address ?? await WalletStore.address();

  if (address != null && looksLikeSugarAddress(address)) {
    await SugarMinerSdk.install(
      config: AppConfig.forAddress(address),
      policy: AppConfig.policy,
      // Starting happens on the consent screen, not here: a fresh install has no
      // consent yet, and an install that auto-started would be mining before the
      // user has read a word of the disclosure.
      autoStart: false,
    );
  }

  runApp(SugarWalletApp(
    wallet: wallet,
    address: address,
    headlessRegistered: registered,
  ));
}

class SugarWalletApp extends StatefulWidget {
  final SugarWallet? wallet;
  final String? address;
  final bool headlessRegistered;
  const SugarWalletApp({
    super.key,
    required this.wallet,
    required this.address,
    required this.headlessRegistered,
  });

  @override
  State<SugarWalletApp> createState() => _SugarWalletAppState();
}

class _SugarWalletAppState extends State<SugarWalletApp> {
  SugarWallet? _wallet;
  String? _address;
  bool _needsOnboarding = false;

  @override
  void initState() {
    super.initState();
    _wallet = widget.wallet;
    _address = widget.address;
    _needsOnboarding = _address == null;
  }

  Future<void> _reload() async {
    final wallet = await WalletStore.load();
    final address = wallet?.address ?? await WalletStore.address();
    if (!mounted) return;
    setState(() {
      _wallet = wallet;
      _address = address;
      _needsOnboarding = address == null;
    });
  }

  /// Called when onboarding finishes. The consent screen has already recorded the
  /// "yes" and started the miner; this only re-reads the wallet so the home screen
  /// shows the address that mining is actually using.
  Future<void> _finishOnboarding() async {
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SUGAR Wallet',
      debugShowCheckedModeBanner: false,
      theme: sugarTheme(),
      home: _needsOnboarding || _address == null
          ? OnboardingScreen(onDone: _finishOnboarding)
          : HomeScreen(
              address: _address!,
              onOpenWallet: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WalletScreen(
                    wallet: _wallet,
                    address: _address!,
                    onChanged: _reload,
                  ),
                ),
              ),
            ),
    );
  }
}
