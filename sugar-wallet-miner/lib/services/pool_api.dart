/// Reads the user's earnings from the pool's own public API.
///
/// No telemetry, no account, no server of ours: the pool already has these
/// numbers because the shares were submitted to it, and this class simply asks
/// for them by address. If the pool is down the app shows what it knows locally
/// and says so — it never invents a balance.
library;

import 'dart:convert';

import 'net.dart';

import '../app_config.dart';

/// The user's own address, as the pool sees it.
class PoolAccount {
  final String address;
  final double hashrate; // H/s across all of this user's devices
  final int shares;
  final double balance; // SUGAR owed but not yet paid
  final double paid; // SUGAR already sent to the address
  final double immature; // SUGAR in blocks the chain has not confirmed yet
  final double networkHashrate; // the whole chain, for the earnings estimate
  final List<PoolDevice> devices;
  final DateTime fetchedAt;
  final String? error;

  const PoolAccount({
    required this.address,
    this.hashrate = 0,
    this.shares = 0,
    this.balance = 0,
    this.paid = 0,
    this.immature = 0,
    this.networkHashrate = 0,
    this.devices = const [],
    required this.fetchedAt,
    this.error,
  });

  double get total => balance + immature;

  /// SUGAR per day at this hashrate, given the chain's live network hashrate.
  ///
  /// The honest arithmetic: the chain issues [PoolInfo.blockReward] every
  /// [PoolInfo.blockSeconds], so a miner holding a share of the network's
  /// hashrate is expected to earn that share of the issuance. It is an estimate
  /// until the shares are actually accepted, and it says nothing about price.
  double? get sugarPerDay {
    if (networkHashrate <= 0 || hashrate <= 0) return null;
    const blocksPerDay = 86400 / PoolInfo.blockSeconds;
    return (hashrate / networkHashrate) * PoolInfo.blockReward * blocksPerDay;
  }

  /// Rough time until the pool has enough to pay out, at the current rate.
  Duration? timeToPayout(double threshold) {
    final perDay = sugarPerDay;
    if (perDay == null || perDay <= 0 || total >= threshold) return null;
    final days = (threshold - total) / perDay;
    if (days > 3650) return null;
    return Duration(seconds: (days * 86400).round());
  }

  factory PoolAccount.fromJson(Map<String, dynamic> j, {String? error}) {
    final workers = (j['workers'] as Map?) ?? const {};
    final devices = <PoolDevice>[];
    workers.forEach((name, info) {
      if (info is Map) {
        devices.add(PoolDevice(
          name: '$name',
          hashrate: (info['hashrate'] as num?)?.toDouble() ?? 0,
          shares: (info['shares'] as num?)?.toInt() ?? 0,
          invalid: (info['invalid'] as num?)?.toInt() ?? 0,
          lastShare: _seconds(info['lastShare']),
        ));
      }
    });
    devices.sort((a, b) => b.hashrate.compareTo(a.hashrate));
    return PoolAccount(
      address: '${j['miner'] ?? j['address'] ?? ''}',
      hashrate: (j['totalHash'] as num?)?.toDouble() ?? 0,
      shares: (j['totalShares'] as num?)?.toInt() ?? 0,
      balance: (j['balance'] as num?)?.toDouble() ?? 0,
      paid: (j['paid'] as num?)?.toDouble() ?? 0,
      immature: (j['immature'] as num?)?.toDouble() ?? 0,
      networkHashrate: (j['networkSols'] as num?)?.toDouble() ?? 0,
      devices: devices,
      fetchedAt: DateTime.now(),
      error: error,
    );
  }

  static DateTime? _seconds(Object? v) {
    final n = v is num ? v.toInt() : int.tryParse('$v');
    if (n == null || n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }
}

class PoolDevice {
  final String name;
  final double hashrate;
  final int shares;
  final int invalid;
  final DateTime? lastShare;
  const PoolDevice({
    required this.name,
    required this.hashrate,
    required this.shares,
    required this.invalid,
    this.lastShare,
  });
}

class PoolApi {
  /// Fetches what the pool knows about [address]. Never throws: a network
  /// problem is an `error` field on an otherwise empty account.
  static Future<PoolAccount> fetch(String address, {Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final stats = await httpGet('${PoolInfo.statsUrl}$address', timeout: timeout);
      final account = PoolAccount.fromJson(
        jsonDecode(stats) as Map<String, dynamic>,
      );
      // the network hashrate lives in the pool-wide stats, not the per-miner one
      try {
        final pool = jsonDecode(await httpGet(PoolInfo.poolStatsUrl, timeout: timeout)) as Map<String, dynamic>;
        final algo = ((pool['algos'] as Map?)?['yespowerSUGAR'] as Map?) ?? const {};
        final network = (algo['networkSols'] as num?)?.toDouble();
        if (network != null && network > 0) {
          return PoolAccount(
            address: account.address,
            hashrate: account.hashrate,
            shares: account.shares,
            balance: account.balance,
            paid: account.paid,
            immature: account.immature,
            networkHashrate: network,
            devices: account.devices,
            fetchedAt: account.fetchedAt,
          );
        }
      } catch (_) {
        // the estimate just stays unavailable; the balance is still real
      }
      return account;
    } catch (e) {
      return PoolAccount(address: address, fetchedAt: DateTime.now(), error: '$e');
    }
  }
}

/// Formatting helpers shared by the screens.
String formatHashrate(double h) {
  if (h <= 0) return '0 H/s';
  if (h >= 1e6) return '${(h / 1e6).toStringAsFixed(2)} MH/s';
  if (h >= 1e3) return '${(h / 1e3).toStringAsFixed(2)} kH/s';
  return '${h.toStringAsFixed(1)} H/s';
}

String formatSugar(double v) {
  if (v == 0) return '0';
  if (v.abs() < 0.001) return v.toStringAsExponential(2);
  if (v.abs() < 1) return v.toStringAsFixed(4);
  if (v.abs() < 1000) return v.toStringAsFixed(2);
  return v.toStringAsFixed(0);
}

String formatDuration(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m';
}
