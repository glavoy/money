import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/features/reports/report_data.dart';
import 'package:money/shared/currency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> addExpense(
    String id,
    DateTime date,
    double amount, {
    String category = 'food',
    String account = 'acc-cash',
  }) async {
    final now = DateTime.now().toUtc();
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: id,
        date: date,
        kind: TxKind.expense,
        amount: amount,
        accountId: account,
        categoryId: Value(seedCategoryId(category, CategoryKind.expense)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  test('period ranges and titles', () {
    final anchor = DateTime.utc(2026, 5, 15);
    final month = reportRange(ReportPeriod.month, anchor);
    expect(month.from, DateTime.utc(2026, 5, 1));
    expect(month.to, DateTime.utc(2026, 5, 31));
    final quarter = reportRange(ReportPeriod.quarter, anchor);
    expect(quarter.from, DateTime.utc(2026, 4, 1));
    expect(quarter.to, DateTime.utc(2026, 6, 30));
    final year = reportRange(ReportPeriod.year, anchor);
    expect(year.from, DateTime.utc(2026, 1, 1));
    expect(year.to, DateTime.utc(2026, 12, 31));
    expect(reportTitle(ReportPeriod.quarter, anchor), 'Q2 2026');
    expect(
      shiftAnchor(ReportPeriod.month, DateTime.utc(2026, 1, 10), -1).month,
      12,
    );
  });

  test('monthly report sums categories and buckets by day', () async {
    await addExpense('e1', DateTime.utc(2026, 5, 2), 10000);
    await addExpense('e2', DateTime.utc(2026, 5, 2), 5000, category: 'beer');
    await addExpense('e3', DateTime.utc(2026, 5, 20), 20000);
    await addExpense('outside', DateTime.utc(2026, 6, 1), 99999);

    final report = await computeReport(
      db: db,
      period: ReportPeriod.month,
      anchor: DateTime.utc(2026, 5, 1),
      currency: Currency.ugx,
    );

    expect(report.expenseTotal, 35000);
    expect(report.byCategory.first.key, 'food');
    expect(report.byCategory.first.value, 30000);
    expect(report.buckets.length, 31);
    expect(report.buckets[1].expense, 15000); // May 2nd
    expect(report.buckets[19].expense, 20000); // May 20th
  });

  test('converts USD account expenses using the fx rate of the day', () async {
    await db.upsertRate(
      date: DateTime.utc(2026, 5, 1),
      usdUgx: 3600,
      cadUgx: 2600,
      source: FxSource.import,
      newId: () => 'fx1',
    );
    await addExpense('e1', DateTime.utc(2026, 5, 2), 100, account: 'acc-visa');
    await addExpense('e2', DateTime.utc(2026, 5, 3), 36000);

    final ugxReport = await computeReport(
      db: db,
      period: ReportPeriod.month,
      anchor: DateTime.utc(2026, 5, 1),
      currency: Currency.ugx,
    );
    expect(ugxReport.expenseTotal, 100 * 3600 + 36000);

    final usdReport = await computeReport(
      db: db,
      period: ReportPeriod.month,
      anchor: DateTime.utc(2026, 5, 1),
      currency: Currency.usd,
    );
    expect(usdReport.expenseTotal, closeTo(100 + 10, 0.001));
  });

  test('flags missing rates instead of guessing', () async {
    await addExpense('e1', DateTime.utc(2026, 5, 2), 100, account: 'acc-visa');
    final report = await computeReport(
      db: db,
      period: ReportPeriod.month,
      anchor: DateTime.utc(2026, 5, 1),
      currency: Currency.ugx,
    );
    expect(report.missingRates, true);
    expect(report.expenseTotal, 0);
  });

  test('transfers do not appear as spending', () async {
    final now = DateTime.now().toUtc();
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: 'tr1',
        date: DateTime.utc(2026, 5, 2),
        kind: TxKind.transfer,
        amount: 1000000,
        accountId: 'acc-cash',
        toAccountId: const Value('acc-mtn'),
        toAmount: const Value(1000000.0),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final report = await computeReport(
      db: db,
      period: ReportPeriod.month,
      anchor: DateTime.utc(2026, 5, 1),
      currency: Currency.ugx,
    );
    expect(report.expenseTotal, 0);
    expect(report.incomeTotal, 0);
  });
}
