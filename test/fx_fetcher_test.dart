import 'package:flutter_test/flutter_test.dart';
import 'package:money/sync/fx_fetcher.dart';

void main() {
  test('parses Frankfurter row responses', () {
    final rates = parseFrankfurterRates('''
[
  {"date":"2026-03-01","base":"USD","quote":"CAD","rate":1.3638},
  {"date":"2026-03-01","base":"USD","quote":"UGX","rate":3583}
]
''');

    expect(rates.usdUgx, 3583);
    expect(rates.usdCad, 1.3638);
    expect(rates.cadUgx, closeTo(2627.22, 0.01));
  });

  test('parses Frankfurter map responses', () {
    final rates = parseFrankfurterRates('''
{
  "base": "USD",
  "date": "2026-03-01",
  "rates": {"CAD": 1.3638, "UGX": 3583}
}
''');

    expect(rates.usdUgx, 3583);
    expect(rates.usdCad, 1.3638);
  });

  test('rejects historical responses missing needed currencies', () {
    expect(
      () => parseFrankfurterRates('{"date":"2026-03-01","rates":{"CAD":1.3}}'),
      throwsFormatException,
    );
  });
}
