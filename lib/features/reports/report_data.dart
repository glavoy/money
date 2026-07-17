import '../../data/database.dart';
import '../../shared/currency.dart';

enum ReportPeriod { month, quarter, year }

class ReportBucket {
  ReportBucket(this.label, this.from, this.to);
  final String label;
  final DateTime from;
  final DateTime to; // inclusive
  double expense = 0;
  double income = 0;
}

class ReportData {
  ReportData({
    required this.from,
    required this.to,
    required this.expenseTotal,
    required this.incomeTotal,
    required this.byCategory,
    required this.buckets,
    required this.missingRates,
  });

  final DateTime from;
  final DateTime to;
  final double expenseTotal;
  final double incomeTotal;

  /// Category name -> converted total, sorted descending.
  final List<MapEntry<String, double>> byCategory;

  /// Sub-period totals (days of a month, months of a quarter/year).
  final List<ReportBucket> buckets;

  /// True when some transactions could not be converted (no FX rate at all).
  final bool missingRates;
}

({DateTime from, DateTime to}) reportRange(
  ReportPeriod period,
  DateTime anchor,
) {
  switch (period) {
    case ReportPeriod.month:
      return (
        from: DateTime.utc(anchor.year, anchor.month, 1),
        to: DateTime.utc(anchor.year, anchor.month + 1, 0),
      );
    case ReportPeriod.quarter:
      final q = ((anchor.month - 1) ~/ 3) * 3 + 1;
      return (
        from: DateTime.utc(anchor.year, q, 1),
        to: DateTime.utc(anchor.year, q + 3, 0),
      );
    case ReportPeriod.year:
      return (
        from: DateTime.utc(anchor.year, 1, 1),
        to: DateTime.utc(anchor.year, 12, 31),
      );
  }
}

DateTime shiftAnchor(ReportPeriod period, DateTime anchor, int delta) {
  switch (period) {
    case ReportPeriod.month:
      return DateTime.utc(anchor.year, anchor.month + delta, 1);
    case ReportPeriod.quarter:
      return DateTime.utc(anchor.year, anchor.month + 3 * delta, 1);
    case ReportPeriod.year:
      return DateTime.utc(anchor.year + delta, anchor.month, 1);
  }
}

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String reportTitle(ReportPeriod period, DateTime anchor) {
  switch (period) {
    case ReportPeriod.month:
      return '${_monthNames[anchor.month - 1]} ${anchor.year}';
    case ReportPeriod.quarter:
      return 'Q${(anchor.month - 1) ~/ 3 + 1} ${anchor.year}';
    case ReportPeriod.year:
      return '${anchor.year}';
  }
}

List<ReportBucket> _makeBuckets(
  ReportPeriod period,
  DateTime from,
  DateTime to,
) {
  switch (period) {
    case ReportPeriod.month:
      return [
        for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
          ReportBucket('${d.day}', d, d),
      ];
    case ReportPeriod.quarter:
    case ReportPeriod.year:
      final buckets = <ReportBucket>[];
      var m = DateTime.utc(from.year, from.month, 1);
      while (!m.isAfter(to)) {
        buckets.add(
          ReportBucket(
            _monthNames[m.month - 1],
            m,
            DateTime.utc(m.year, m.month + 1, 0),
          ),
        );
        m = DateTime.utc(m.year, m.month + 1, 1);
      }
      return buckets;
  }
}

Future<ReportData> computeReport({
  required AppDatabase db,
  required String ledgerId,
  required ReportPeriod period,
  required DateTime anchor,
  required Currency currency,
}) async {
  final range = reportRange(period, anchor);
  final txs = await db.getTransactionsBetween(
    range.from,
    range.to,
    ledgerId: ledgerId,
  );
  final accounts = await db.getAccounts(
    ledgerId: ledgerId,
    includeArchived: true,
  );
  final categories = await db.getCategories(
    ledgerId: ledgerId,
    includeArchived: true,
  );
  final accountCurrency = {
    for (final a in accounts) a.id: CurrencyX.fromCode(a.currency),
  };
  final categoryName = {for (final c in categories) c.id: c.name};

  // FX table covering the range, with one earlier row as fallback.
  final rates = await db.getRatesBetween(
    range.from.subtract(const Duration(days: 45)),
    range.to,
  );
  if (rates.isEmpty) {
    final fallback = await db.getRateOn(range.from);
    if (fallback != null) rates.add(fallback);
  }
  final fx = FxTable(rates);

  final buckets = _makeBuckets(period, range.from, range.to);
  final byCategory = <String, double>{};
  double expenseTotal = 0, incomeTotal = 0;
  var missingRates = false;

  for (final t in txs) {
    if (t.kind == TxKind.transfer) continue;
    final from = accountCurrency[t.accountId] ?? Currency.ugx;
    final converted = fx.convert(t.amount, from, currency, t.date);
    if (converted == null) {
      missingRates = true;
      continue;
    }
    if (t.kind == TxKind.expense) {
      expenseTotal += converted;
      final name = categoryName[t.categoryId] ?? 'Uncategorised';
      byCategory[name] = (byCategory[name] ?? 0) + converted;
    } else {
      incomeTotal += converted;
    }
    for (final b in buckets) {
      if (!t.date.isBefore(b.from) && !t.date.isAfter(b.to)) {
        if (t.kind == TxKind.expense) {
          b.expense += converted;
        } else {
          b.income += converted;
        }
        break;
      }
    }
  }

  final sorted = byCategory.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return ReportData(
    from: range.from,
    to: range.to,
    expenseTotal: expenseTotal,
    incomeTotal: incomeTotal,
    byCategory: sorted,
    buckets: buckets,
    missingRates: missingRates,
  );
}
