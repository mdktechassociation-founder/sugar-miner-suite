import 'package:flutter/material.dart';

import '../disclosure.dart';
import '../miner_api.dart';
import '../sugar_config.dart';

/// The one screen the SDK would like the user to see: what this app does to
/// their phone, in plain words, with a real choice.
///
/// The app's own terms and privacy policy carry the legal weight (see
/// [MiningDisclosure]); this screen exists so the mining is never *only* in a
/// document nobody opened.
///
/// Branding it is expected: pass [builder] and draw it however the app likes —
/// the SDK only cares that the user is shown [MiningDisclosure.miningNotice] and
/// that "no" is a real option.
class SugarConsentSheet extends StatelessWidget {
  final SugarMinerApi? miner;
  final String appName;

  /// Draw your own content instead of the default sheet. Call `onDecision(true)`
  /// when the user agrees, `onDecision(false)` when they decline.
  final Widget Function(BuildContext, MiningDisclosure, void Function(bool))? builder;

  const SugarConsentSheet({
    super.key,
    this.miner,
    this.appName = 'This app',
    this.builder,
  });

  /// Shows the disclosure and records the answer. Returns true only on a "yes".
  static Future<bool> show(
    BuildContext context, {
    SugarMinerApi? miner,
    String appName = 'This app',
    Widget Function(BuildContext, MiningDisclosure, void Function(bool))? builder,
  }) async {
    final agreed = await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => SugarConsentSheet(miner: miner, appName: appName, builder: builder),
        ) ??
        false;

    if (miner != null) {
      if (agreed) {
        await miner.recordConsent();
      } else {
        await miner.withdrawConsent();
      }
    }
    // nothing to record against without a miner — the host app's own store wins
    return agreed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disclosure = miner?.config.disclosure;
    final policy = miner?.policy ?? const MiningPolicy();

    if (disclosure == null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'No mining disclosure was configured, so mining cannot be offered. '
          'Set SugarConfig.disclosure.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    void decide(bool agreed) => Navigator.of(context).pop(agreed);

    if (builder != null) return builder!(context, disclosure, decide);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('About mining', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(disclosure.miningNotice, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            const _Bullet(
              icon: Icons.speed,
              text: 'It uses a small slice of your phone\'s processor and a little '
                  'network data.',
            ),
            _Bullet(
              icon: Icons.tune,
              text: 'By default that is about ${policy.cpuSharePercent}% of one CPU core, '
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
              text: 'A notification is shown the whole time and cannot be hidden or '
                  'swiped away. It has a stop button in it.',
            ),
            const _Bullet(
              icon: Icons.power_settings_new,
              text: 'You can stop it any time, here or from that notification, and it '
                  'will not start again by itself.',
            ),
            const SizedBox(height: 8),
            // Who benefits, and the documents. No wallet strings, no pool names,
            // no mining arithmetic: the user is deciding whether to lend spare
            // power, not auditing a rig.
            Text(
              'Mining for ${disclosure.ownerName}\n'
              'Terms: ${disclosure.termsUrl} (v${disclosure.termsVersion})\n'
              'Privacy: ${disclosure.privacyUrl}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => decide(true),
              child: const Text('Agree and allow mining'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => decide(false),
              child: const Text('No thanks'),
            ),
          ],
        ),
      ),
    );
  }

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
