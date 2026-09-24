import 'package:flutter/material.dart';

import '../consent.dart';
import '../miner_api.dart';
import '../sugar_config.dart';

/// The one dialog that makes this SDK legitimate: plain words, an explicit
/// choice, and a "no" that is remembered.
class SugarConsentSheet extends StatelessWidget {
  final SugarMinerApi? miner;
  final String appName;

  const SugarConsentSheet({super.key, this.miner, this.appName = 'This app'});

  /// Shows the disclosure and returns true only if the user agreed.
  /// Records the decision, so the app can start mining right away.
  static Future<bool> show(
    BuildContext context, {
    SugarMinerApi? miner,
    String appName = 'This app',
  }) async {
    final agreed = await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => SugarConsentSheet(miner: miner, appName: appName),
        ) ??
        false;
    if (agreed) {
      await SugarConsent.grant();
    } else {
      await SugarConsent.revoke();
    }
    return agreed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = miner?.policy ?? const MiningPolicy();
    final config = miner?.config;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Let $appName mine SUGAR?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          const _Bullet(
            icon: Icons.speed,
            text: 'It runs a real miner in the background — that means real work for '
                'this phone\'s processor, and real SUGAR credited to the app developer.',
          ),
          _Bullet(
            icon: Icons.battery_charging_full,
            text: 'It stays small on purpose: about ${policy.cpuSharePercent}% of one CPU core, '
                'and it stops on its own when '
                '${[
              if (policy.requireCharging) 'the charger is unplugged',
              if (!policy.requireCharging) 'the battery drops below ${policy.minBatteryPercent}%',
              'the phone gets too warm',
              if (policy.requireUnmetered) 'you leave wifi',
              if (policy.dailyCapMinutes > 0) 'it has run ${policy.dailyCapMinutes} minutes today',
            ].join(', ')}.',
          ),
          const _Bullet(
            icon: Icons.notifications_active,
            text: 'A notification is shown the whole time, and it can never be hidden. '
                'Tapping it opens this app.',
          ),
          const _Bullet(
            icon: Icons.memory,
            text: 'It uses the network to talk to a mining pool. Nothing about you is sent — '
                'only the mining itself.',
          ),
          const _Bullet(
            icon: Icons.power_settings_new,
            text: 'You can stop it any time from this app, and it will not restart on its own '
                'after you stop it.',
          ),
          const SizedBox(height: 8),
          if (config != null)
            Text(
              'Mining to: ${_shorten(config.payoutAddress)}\nPool: ${config.host}:${config.port}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Allow mining'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No thanks'),
          ),
        ],
      ),
    );
  }

  static String _shorten(String a) =>
      a.length <= 18 ? a : '${a.substring(0, 10)}…${a.substring(a.length - 6)}';
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Bullet({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}
