/// What one SUGAR is worth right now, fetched from a public price feed.
///
/// This exists so the app can say "about $0.0002 a day" instead of leaving the
/// user to work out what 2 SUGAR means. It is deliberately careful about three
/// things:
///
///   * it names its source, so the number is checkable rather than mystical,
///   * it caches for five minutes, so the app is not hammering somebody's API on
///     every screen refresh,
///   * it never lets a missing price break the earnings screen — a failure
///     renders as "—", not as zero and not as a made-up figure.
///
/// SUGAR is a small, thinly traded coin. The price here is an indication, not a
/// quote, and the app says so where the number appears.
library;

import 'dart:convert';
import 'dart:io';

import 'history.dart';

class SugarPrice {
  final double usd;
  final DateTime? fetchedAt;
  final String? error;

  const SugarPrice({required this.usd, this.fetchedAt, this.error});

  bool get isKnown => usd > 0;

  /// How old this figure is, for the "as of" line under it.
  Duration get age => fetchedAt == null
      ? Duration.zero
      : DateTime.now().difference(fetchedAt!);

  String get usdLabel {
    if (!isKnown) return '—';
    if (usd < 0.0001) return '\$${usd.toStringAsExponential(2)}';
    if (usd < 0.01) return '\$${usd.toStringAsFixed(6)}';
    return '\$${usd.toStringAsFixed(4)}';
  }

  /// What [sugar] is worth, in USD. Null when the price is unknown — a caller
  /// that gets null must show a dash rather than guess.
  double? valueOf(double sugar) => isKnown ? sugar * usd : null;
}

class PriceApi {
  static const _url =
      'https://api.coingecko.com/api/v3/simple/price?ids=sugarchain&vs_currencies=usd';
  static const _cacheFor = Duration(minutes: 5);

  static SugarPrice? _cache;
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<SugarPrice> fetch({bool force = false}) async {
    final now = DateTime.now();
    final cached = _cache;
    if (!force && cached != null && now.difference(_cachedAt) < _cacheFor) {
      return cached;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(_url));
      request.headers.set(HttpHeaders.userAgentHeader, 'sugar-wallet/1.0');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(_url));
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final sugar = (json['sugarchain'] as Map?) ?? const {};
      final usd = (sugar['usd'] as num?)?.toDouble() ?? 0;
      final price = SugarPrice(usd: usd, fetchedAt: now);
      _cache = price;
      _cachedAt = now;
      // Every genuine fetch adds a point to the phone's own price history, which
      // is what the sparkline draws. Cached reads deliberately do not: a chart
      // of repeated cache hits would be a flat line pretending to be a market.
      if (usd > 0) await SampleHistory.record(SampleHistory.priceUsd, usd);
      return price;
    } catch (e) {
      // Keep the last good price rather than dropping to nothing: a stale
      // indication with its timestamp beats a blank screen.
      if (cached != null && cached.isKnown) {
        return SugarPrice(usd: cached.usd, fetchedAt: cached.fetchedAt, error: '$e');
      }
      return SugarPrice(usd: 0, fetchedAt: now, error: '$e');
    } finally {
      client.close(force: true);
    }
  }
}
