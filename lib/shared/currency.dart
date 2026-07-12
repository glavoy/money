import 'package:intl/intl.dart';

import '../data/database.dart';

enum Currency { ugx, usd, cad }

extension CurrencyX on Currency {
  String get code => switch (this) {
    Currency.ugx => 'UGX',
    Currency.usd => 'USD',
    Currency.cad => 'CAD',
  };

  static Currency fromCode(String code) => switch (code.toUpperCase()) {
    'USD' => Currency.usd,
    'CAD' => Currency.cad,
    _ => Currency.ugx,
  };
}

final _ugxFormat = NumberFormat('#,##0', 'en_US');
final _decimalFormat = NumberFormat('#,##0.00', 'en_US');

String formatMoney(double amount, Currency currency, {bool withCode = true}) {
  final formatted = currency == Currency.ugx
      ? _ugxFormat.format(amount)
      : _decimalFormat.format(amount);
  return withCode ? '$formatted ${currency.code}' : formatted;
}

/// Converts between UGX/USD/CAD using an FX rate row.
///
/// Returns null when the rate needed for the pair is missing.
double? convertWithRate(
  double amount,
  Currency from,
  Currency to,
  FxRate? rate,
) {
  if (from == to) return amount;
  if (rate == null) return null;

  // Convert everything through UGX.
  double? inUgx;
  switch (from) {
    case Currency.ugx:
      inUgx = amount;
    case Currency.usd:
      inUgx = rate.usdUgx == null ? null : amount * rate.usdUgx!;
    case Currency.cad:
      inUgx = rate.cadUgx == null ? null : amount * rate.cadUgx!;
  }
  if (inUgx == null) return null;

  switch (to) {
    case Currency.ugx:
      return inUgx;
    case Currency.usd:
      return rate.usdUgx == null || rate.usdUgx == 0
          ? null
          : inUgx / rate.usdUgx!;
    case Currency.cad:
      return rate.cadUgx == null || rate.cadUgx == 0
          ? null
          : inUgx / rate.cadUgx!;
  }
}

/// Snapshot of FX rates over a period, used to convert many transactions
/// without hitting the database per row.
class FxTable {
  FxTable(List<FxRate> rates)
    : _rates = List.of(rates)..sort((a, b) => a.date.compareTo(b.date));

  final List<FxRate> _rates;

  bool get isEmpty => _rates.isEmpty;

  /// Latest rate on or before [date]; falls back to the earliest known rate.
  FxRate? rateOn(DateTime date) {
    if (_rates.isEmpty) return null;
    FxRate? best;
    // Binary search for the last rate with rate.date <= date.
    var lo = 0, hi = _rates.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (_rates[mid].date.isAfter(date)) {
        hi = mid - 1;
      } else {
        best = _rates[mid];
        lo = mid + 1;
      }
    }
    return best ?? _rates.first;
  }

  double? convert(double amount, Currency from, Currency to, DateTime date) =>
      convertWithRate(amount, from, to, rateOn(date));
}
