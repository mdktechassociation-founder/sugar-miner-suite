import 'package:shared_preferences/shared_preferences.dart';

/// Where the app keeps the payout address, worker name and pool.
/// Read by both the UI isolate and the background-service isolate.
class AppSettings {
  final String wallet;
  final String worker;
  final String host;
  final int port;

  const AppSettings({
    required this.wallet,
    required this.worker,
    required this.host,
    required this.port,
  });

  static const defaults = AppSettings(
    wallet: '',
    worker: 'phone',
    host: 'stratum.poolab.org',
    port: 8451,
  );

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      wallet: p.getString('wallet') ?? defaults.wallet,
      worker: p.getString('worker') ?? defaults.worker,
      host: p.getString('host') ?? defaults.host,
      port: p.getInt('port') ?? defaults.port,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('wallet', wallet);
    await p.setString('worker', worker);
    await p.setString('host', host);
    await p.setInt('port', port);
  }

  AppSettings copyWith({String? wallet, String? worker, String? host, int? port}) => AppSettings(
        wallet: wallet ?? this.wallet,
        worker: worker ?? this.worker,
        host: host ?? this.host,
        port: port ?? this.port,
      );

  /// SUGAR bech32 addresses: sugar1q… (mainnet), tugar1… (testnet)
  static bool isValidAddress(String a) =>
      RegExp(r'^(sugar1|tugar1)[0-9a-z]{25,}$').hasMatch(a.trim());
}
