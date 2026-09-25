/// Small ring buffers of the two things worth plotting on the home screen: what
/// one SUGAR has been worth, and how fast this phone has been hashing.
///
/// Why the app keeps its own history instead of asking a price API for a chart:
/// the free tiers of every public feed throttle the history endpoints, and a
/// sparkline that is sometimes real and sometimes a cached invention is worse
/// than no sparkline. These samples are what this app actually saw on this
/// phone, so the chart can be labelled honestly and it gets better the longer
/// the app runs.
///
/// Storage is ordinary preferences, not the keystore: a price trend and a
/// hashrate trend are not secrets, and the keystore is reserved for the key.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class Sample {
  final DateTime at;
  final double value;

  const Sample(this.at, this.value);

  Map<String, Object?> toJson() => {'t': at.millisecondsSinceEpoch, 'v': value};

  static Sample? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['t'];
    final v = raw['v'];
    if (t is! int || v is! num) return null;
    return Sample(DateTime.fromMillisecondsSinceEpoch(t), v.toDouble());
  }
}

class SampleHistory {
  /// What one SUGAR was worth, in USD. Five-minute cadence, a day of samples.
  static const priceUsd = 'price_usd';

  /// This phone's hashrate. Sampled with the live stats, an hour of samples.
  static const hashrate = 'hashrate_hps';

  static String _key(String name) => 'history_v1_$name';

  /// The stored series, oldest first. Never throws: a corrupt entry reads as an
  /// empty history rather than taking the home screen down with it.
  static Future<List<Sample>> load(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(name));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(Sample.fromJson)
          .whereType<Sample>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Appends [value] unless the newest sample is younger than [minGap], then
  /// trims to the most recent [keep] entries.
  ///
  /// The gap matters because the home screen re-reads the miner every twenty
  /// seconds: without it the hashrate series would be one flat minute repeated
  /// and the price series would be whatever the cache returned.
  static Future<List<Sample>> record(
    String name,
    double value, {
    int keep = 288,
    Duration minGap = const Duration(minutes: 4),
  }) async {
    if (value.isNaN || value.isInfinite) return load(name);
    final now = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final series = (await load(name)).toList();
      if (series.isNotEmpty && now.difference(series.last.at) < minGap) {
        // Too soon to add a point: leave the series alone, including its length.
        return series;
      }
      series.add(Sample(now, value));
      while (series.length > keep) {
        series.removeAt(0);
      }
      await prefs.setString(
          _key(name), jsonEncode(series.map((s) => s.toJson()).toList()));
      return series;
    } catch (_) {
      return const [];
    }
  }

  /// Just the values, for the sparkline.
  static Future<List<double>> values(String name) async =>
      (await load(name)).map((s) => s.value).toList(growable: false);

  static Future<void> clear(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(name));
    } catch (_) {
      // Nothing to do: not being able to clear a chart is not worth a crash.
    }
  }
}
