/// The SDK's *own* Dart entrypoint, for apps that want the miner attached
/// without writing any Dart themselves.
///
/// Normally the host app registers a function of its own and calls
/// `registerHeadlessEntrypoint`. That is the thorough way, and it stays the
/// documented way. This is the shortcut: the SDK ships a function of its own, the
/// host app imports this library **once** (no calls, no widgets, no changes to
/// any screen), and the native side starts it.
///
/// Why an import is still needed — and why that is not laziness on our part:
/// Flutter compiles an app into one AOT snapshot, and a library the app never
/// imports is not in that snapshot at all. So a named entrypoint can only be
/// called if the app's own Dart refers to this library somewhere. One import line
/// is the smallest true thing; anything smaller would only work in debug builds,
/// which is worse than useless because it would fail in release.
///
/// Configuration comes from the host app's AndroidManifest (`<meta-data>`), read
/// by the native side, so the address and the disclosure text live where an
/// integrator already looks. Nothing here decides anything by itself: if the
/// metadata is missing, or consent was never recorded, this entrypoint starts
/// nothing at all.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../sugar_miner_sdk.dart' show SugarMinerSdk;
// The three config types live in their own files; the facade re-exports them, but
// referring to them directly keeps this file's dependencies readable.
import 'disclosure.dart';
import 'notification_style.dart';
import 'sugar_config.dart';

const MethodChannel _channel = MethodChannel('sugar_miner_sdk');

/// The manifest metadata the native installer reads, and this entrypoint uses.
class NativeConfig {
  final String payoutAddress;
  final String appName;
  final String ownerName;
  final String miningNotice;
  final String noticeVersion;
  final String termsUrl;
  final String termsVersion;
  final String privacyUrl;
  final int cpuSharePercent;
  final int dailyCapMinutes;
  final bool requireUnmetered;

  const NativeConfig({
    required this.payoutAddress,
    required this.appName,
    required this.ownerName,
    required this.miningNotice,
    required this.noticeVersion,
    required this.termsUrl,
    required this.termsVersion,
    required this.privacyUrl,
    required this.cpuSharePercent,
    required this.dailyCapMinutes,
    required this.requireUnmetered,
  });

  /// The exact string the consent is recorded against, identical to
  /// [MiningDisclosure.consentVersion] and to what the native consent dialog
  /// writes when the user agrees.
  String get consentVersion => '$noticeVersion|terms:$termsVersion|privacy:$privacyUrl';

  SugarConfig toSugarConfig() => SugarConfig(
        payoutAddress: payoutAddress,
        disclosure: MiningDisclosure(
          appName: appName,
          ownerName: ownerName,
          miningNotice: miningNotice,
          noticeVersion: noticeVersion,
          termsUrl: termsUrl,
          termsVersion: termsVersion,
          privacyUrl: privacyUrl,
        ),
        notification: NotificationStyle(
          titleTemplate: '$appName · using your spare power',
          bodyTemplate: 'Mining SUGAR for $appName, which keeps it free. Stop any time.',
          channelId: 'sugar_miner_${_slug(appName)}',
          channelName: 'Keeping $appName free',
        ),
      );

  MiningPolicy get policy => MiningPolicy(
        cpuSharePercent: cpuSharePercent,
        dailyCapMinutes: dailyCapMinutes,
        requireUnmetered: requireUnmetered,
      );

  static String _slug(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').padRight(3, 'x').substring(0, 12);

  /// Reads the host app's `<meta-data>` through the plugin.
  static Future<NativeConfig?> fetch() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('nativeConfig');
      if (map == null) return null;
      final address = '${map['payoutAddress'] ?? ''}';
      if (!RegExp(r'^(sugar1|tugar1)[0-9a-z]{25,}$').hasMatch(address)) {
        // No address (or one the miner would refuse) means there is nothing to
        // mine into. Doing nothing is the only correct answer.
        return null;
      }
      return NativeConfig(
        payoutAddress: address,
        appName: '${map['appName'] ?? 'This app'}',
        ownerName: '${map['ownerName'] ?? 'the app developer'}',
        miningNotice: '${map['miningNotice'] ?? ''}',
        noticeVersion: '${map['noticeVersion'] ?? '1.0.0'}',
        termsUrl: '${map['termsUrl'] ?? ''}',
        termsVersion: '${map['termsVersion'] ?? ''}',
        privacyUrl: '${map['privacyUrl'] ?? ''}',
        cpuSharePercent: (map['cpuSharePercent'] as int?) ?? 25,
        dailyCapMinutes: (map['dailyCapMinutes'] as int?) ?? 480,
        requireUnmetered: (map['requireUnmetered'] as bool?) ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Called by the native installer after the user has agreed in the SDK's own
/// consent dialog. Everything it does is gated by the same rules as any other
/// install: `install()` refuses to start without a recorded consent for this
/// exact notice version, which is what the dialog just wrote.
@pragma('vm:entry-point')
Future<void> sugarMinerSdkHeadless() async {
  WidgetsFlutterBinding.ensureInitialized();

  final native = await NativeConfig.fetch();
  if (native == null) return;

  await SugarMinerSdk.install(
    config: native.toSugarConfig(),
    policy: native.policy,
  );
}
