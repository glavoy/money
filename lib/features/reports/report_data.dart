import '../../data/database.dart';
import '../../shared/currency.dart';

enum ReportPeriod { month, quarter, year, all }

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
    this.prevExpenseTotal,
    this.prevIncomeTotal,
  });

  final DateTime from;
  final DateTime to;
  final double expenseTotal;
  final double incomeTotal;

  /// Category name -> converted total, sorted descending.
  final List<MapEntry<String, double>> byCategory;

  /// Sub-period totals (days of a month, months of a quarter/year,
  /// years of the all-time view).
  final List<ReportBucket> buckets;

  /// True when some transactions could not be converted (no FX rate at all).
  final bool missingRates;

  /// Totals for the immediately preceding period, for "vs previous"
  /// comparisons. Null for the all-time view (there is no previous).
  final double? prevExpenseTotal;
  final double? prevIncomeTotal;
}

({DateTime from, DateTime to}) reportRange(
  ReportPeriod period,
  DateTime anchor, {
  DateTime? earliest,
}) {
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
    case ReportPeriod.all:
      final now = DateTime.now();
      final start = earliest ?? DateTime.utc(now.year);
      return (
        from: DateTime.utc(start.year),
        to: DateTime.utc(now.year, 12, 31),
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
    case ReportPeriod.all:
      return anchor; // The all-time view has nothing to step through.
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
    case ReportPeriod.all:
      return 'All years';
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
    case ReportPeriod.all:
      return [
        for (var y = from.year; y <= to.year; y++)
          ReportBucket('$y', DateTime.utc(y), DateTime.utc(y, 12, 31)),
      ];
  }
}

/// Loads an FX table covering [from]..[to], with one earlier row as fallback.
Future<FxTable> _loadFxTable(AppDatabase db, DateTime from, DateTime to) async {
  final rates = await db.getRatesBetween(
    from.subtract(const Duration(days: 45)),
    to,
  );
  if (rates.isEmpty) {
    final fallback = await db.getRateOn(from);
    if (fallback != null) rates.add(fallback);
  }
  return FxTable(rates);
}

/// Converted expense/income totals for a range; used for the "vs previous
/// period" comparison without building full buckets.
Future<({double expense, double income})> _totalsBetween(
  AppDatabase db, {
  required String ledgerId,
  required DateTime from,
  required DateTime to,
  required Currency currency,
  required Map<String, Currency> accountCurrency,
}) async {
  final txs = await db.getTransactionsBetween(from, to, ledgerId: ledgerId);
  final fx = await _loadFxTable(db, from, to);
  double expense = 0, income = 0;
  for (final t in txs) {
    if (t.kind == TxKind.transfer || t.excludeFromReport) continue;
    final fromCurrency = accountCurrency[t.accountId] ?? Currency.ugx;
    final converted = fx.convert(t.amount, fromCurrency, currency, t.date);
    if (converted == null) continue;
    if (t.kind == TxKind.expense) {
      expense += converted;
    } else {
      income += converted;
    }
  }
  return (expense: expense, income: income);
}

Future<ReportData> computeReport({
  required AppDatabase db,
  required String ledgerId,
  required ReportPeriod period,
  required DateTime anchor,
  required Currency currency,
}) async {
  final earliest = period == ReportPeriod.all
      ? await db.getFirstTransactionDate(ledgerId: ledgerId)
      : null;
  final range = reportRange(period, anchor, earliest: earliest);
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

  final fx = await _loadFxTable(db, range.from, range.to);

  final buckets = _makeBuckets(period, range.from, range.to);
  final byCategory = <String, double>{};
  double expenseTotal = 0, incomeTotal = 0;
  var missingRates = false;

  for (final t in txs) {
    if (t.kind == TxKind.transfer || t.excludeFromReport) continue;
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

  ({double expense, double income})? prev;
  if (period != ReportPeriod.all) {
    final prevRange = reportRange(period, shiftAnchor(period, anchor, -1));
    prev = await _totalsBetween(
      db,
      ledgerId: ledgerId,
      from: prevRange.from,
      to: prevRange.to,
      currency: currency,
      accountCurrency: accountCurrency,
    );
  }

  return ReportData(
    from: range.from,
    to: range.to,
    expenseTotal: expenseTotal,
    incomeTotal: incomeTotal,
    byCategory: sorted,
    buckets: buckets,
    missingRates: missingRates,
    prevExpenseTotal: prev?.expense,
    prevIncomeTotal: prev?.income,
  );
}
