/// Everything about *this* app's use of the miner SDK, in one file.
///
/// The difference from a developer-hosted app is who benefits. Here the user
/// mines to a wallet they hold, so the disclosure says so in plain words, and the
/// payout address is not a constant in the source — it is whatever wallet this
/// device created. That is why the config is built by a function, not a `const`.
library;

import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

class AppConfig {
  /// Shown in the consent screen and in the notification.
  static const appName = 'SUGAR Wallet';
  static const termsUrl = 'https://github.com/mdktechassociation-founder/sugar-miner-suite/blob/main/sugar-wallet-miner/TERMS.md';
  static const privacyUrl = 'https://github.com/mdktechassociation-founder/sugar-miner-suite/blob/main/sugar-wallet-miner/PRIVACY.md';
  static const termsVersion = '2026-09-24';

  /// The user is the beneficiary, so their own wallet is the payout address.
  ///
  /// `ownerName` matters: the SDK's consent screen says "Mining for <ownerName>",
  /// and printing a wallet string there would be noise. In this app the honest
  /// answer is "you".
  static SugarConfig forAddress(String address) => SugarConfig(
        payoutAddress: address,
        disclosure: const MiningDisclosure(
          appName: appName,
          ownerName: 'you',
          miningNotice:
              'This app mines SUGAR cryptocurrency for you, using a small part of this '
              'phone\'s spare processing power. The coins go to the wallet this app '
              'created for you on this device — nobody else can spend them, including '
              'the developer. Mining only runs when the phone is not busy, and pauses '
              'by itself when it is hot, on low battery or on mobile data. A '
              'notification is shown the whole time it runs, and you can stop it at '
              'any time from the app or from that notification.',
          noticeVersion: '1.0.0',
          termsUrl: termsUrl,
          termsVersion: termsVersion,
          privacyUrl: privacyUrl,
        ),
        notification: const NotificationStyle(
          titleTemplate: 'Mining SUGAR for your wallet',
          bodyTemplate: 'Your own address is earning. Stop any time.',
          channelId: 'sugar_wallet_mining',
          channelName: 'Mining for your wallet',
          channelDescription:
              'Shown while this app mines SUGAR to the wallet on this device.',
        ),
      );

  /// Deliberately gentle defaults: this runs on a phone someone is using.
  static const policy = MiningPolicy(
    cpuSharePercent: 25,
    dailyCapMinutes: 720,
    requireCharging: false,
    requireUnmetered: true,
    minBatteryPercent: 30,
    maxThermalStatus: 3,
  );
}

/// Pool endpoints and the public stats API this app reads to show earnings.
///
/// The app never reports anything anywhere: it asks the pool what the pool
/// already knows about the user's own address.
class PoolInfo {
  static const stratum = 'stratum.poolab.org:8451';
  static const statsUrl = 'https://poolab.org/api/worker_stats?address=';
  static const poolStatsUrl = 'https://poolab.org/api/stats?coin=sugarchain';
  static const explorer = 'https://sugar.bitaps.com/address/';

  /// The chain's economics, for the earnings estimate. From Sugarchain's own
  /// source: 42.94967296 SUGAR per block, 5-second blocks (so 17,280 a day).
  static const blockReward = 42.94967296;
  static const blockSeconds = 5;
}
