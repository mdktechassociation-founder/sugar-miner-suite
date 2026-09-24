// What the sparklines are allowed to draw, and — more importantly — what they
// are not. The charts on the home screen are the only place in this app where a
// number is invented rather than read from somewhere, so the rule is that they
// may only ever plot samples this phone actually recorded.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sugar_wallet_miner/services/history.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an empty history is empty, not zero', () async {
    expect(await SampleHistory.load(SampleHistory.priceUsd), isEmpty);
    expect(await SampleHistory.values(SampleHistory.priceUsd), isEmpty);
  });

  test('samples survive a round trip through storage', () async {
    await SampleHistory.record(SampleHistory.priceUsd, 0.00014,
        minGap: Duration.zero);
    await SampleHistory.record(SampleHistory.priceUsd, 0.00016,
        minGap: Duration.zero);
    final series = await SampleHistory.load(SampleHistory.priceUsd);
    expect(series.length, 2);
    expect(series.first.value, closeTo(0.00014, 1e-12));
    expect(series.last.value, closeTo(0.00016, 1e-12));
    expect(series.last.at.isAfter(series.first.at), isTrue);
  });

  test('a second reading inside the gap does not add a point', () async {
    // The home screen re-reads the miner every twenty seconds; without this the
    // chart would be one flat minute repeated instead of a trend.
    await SampleHistory.record(SampleHistory.priceUsd, 0.00014,
        minGap: const Duration(minutes: 4));
    final after = await SampleHistory.record(SampleHistory.priceUsd, 0.00020,
        minGap: const Duration(minutes: 4));
    expect(after.length, 1);
    expect(after.single.value, closeTo(0.00014, 1e-12),
        reason: 'the too-soon reading must not overwrite the stored one');
  });

  test('the series is trimmed to the newest points', () async {
    for (var i = 0; i < 6; i++) {
      await SampleHistory.record(SampleHistory.hashrate, i.toDouble(),
          keep: 3, minGap: Duration.zero);
    }
    final series = await SampleHistory.load(SampleHistory.hashrate);
    expect(series.length, 3);
    expect(series.map((s) => s.value).toList(), [3.0, 4.0, 5.0]);
  });

  test('a nonsense reading is refused rather than plotted', () async {
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      await SampleHistory.record(SampleHistory.hashrate, bad,
          minGap: Duration.zero);
    }
    expect(await SampleHistory.load(SampleHistory.hashrate), isEmpty);
  });

  test('corrupt storage reads as no history instead of throwing', () async {
    SharedPreferences.setMockInitialValues({'history_v1_price_usd': 'not json'});
    expect(await SampleHistory.load(SampleHistory.priceUsd), isEmpty);
  });

  test('entries that are not samples are skipped, not fatal', () async {
    SharedPreferences.setMockInitialValues({
      'history_v1_price_usd': '[{"t":1,"v":2.0},{"nope":true},[3],{"t":"x","v":1}]',
    });
    final series = await SampleHistory.load(SampleHistory.priceUsd);
    expect(series.length, 1);
    expect(series.single.value, closeTo(2.0, 1e-12));
  });

  test('clearing removes the series', () async {
    await SampleHistory.record(SampleHistory.priceUsd, 1, minGap: Duration.zero);
    await SampleHistory.clear(SampleHistory.priceUsd);
    expect(await SampleHistory.load(SampleHistory.priceUsd), isEmpty);
  });
}
