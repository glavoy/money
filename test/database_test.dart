import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:expense_tracker/data/database.dart';
import 'package:expense_tracker/data/seed.dart';
import 'package:expense_tracker/shared/currency.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase _openTestDb() => AppDatabase(NativeDatabase.memory());

TransactionsCompanion _tx({
  required String id,
  required DateTime date,
  required String kind,
  required double amount,
  required String accountId,
  String? categoryId,
  String? toAccountId,
  double? toAmount,
}) {
  final now = DateTime.now().toUtc();
  return TransactionsCompanion.insert(
    id: id,
    date: date,
    kind: kind,
    amount: amount,
    accountId: accountId,
    categoryId: Value(categoryId),
    toAccountId: Value(toAccountId),
    toAmount: Value(toAmount),
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('seeding', () {
    test('seeds accounts and categories on create', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final accounts = await db.getAccounts(includeArchived: true);
      final categories = await db.getCategories(includeArchived: true);
      expect(accounts.length, seedAccounts.length);
      expect(
        categories.length,
        seedExpenseCategories.length + seedIncomeCategories.length,
      );
      // History account is archived so it stays out of quick-add.
      expect(accounts.singleWhere((a) => a.id == historyAccountId).archived, true);
    });
  });

  group('balances', () {
    test('computes opening + income - expense + transfers', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final day = DateTime.utc(2026, 7, 1);

      // Opening balance on cash.
      await (db.update(db.accounts)..where((a) => a.id.equals('acc-cash'))).write(
        AccountsCompanion(
          openingBalance: const Value(100000),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

      await db.upsertTransaction(_tx(
        id: 't1',
        date: day,
        kind: TxKind.expense,
        amount: 30000,
        accountId: 'acc-cash',
        categoryId: seedCategoryId('food', CategoryKind.expense),
      ));
      await db.upsertTransaction(_tx(
        id: 't2',
        date: day,
        kind: TxKind.income,
        amount: 50000,
        accountId: 'acc-cash',
        categoryId: seedCategoryId('Salary', CategoryKind.income),
      ));
      // Currency exchange: $100 -> 360,000 UGX cash.
      await db.upsertTransaction(_tx(
        id: 't3',
        date: day,
        kind: TxKind.transfer,
        amount: 100,
        accountId: 'acc-usd-bank',
        toAccountId: 'acc-cash',
        toAmount: 360000,
      ));

      final balances = await db.watchBalances(includeArchived: true).first;
      final byId = {for (final b in balances) b.account.id: b.balance};
      expect(byId['acc-cash'], 100000 - 30000 + 50000 + 360000);
      expect(byId['acc-usd-bank'], -100);
    });

    test('soft-deleted transactions do not count', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      await db.upsertTransaction(_tx(
        id: 't1',
        date: DateTime.utc(2026, 7, 1),
        kind: TxKind.expense,
        amount: 5000,
        accountId: 'acc-cash',
        categoryId: seedCategoryId('food', CategoryKind.expense),
      ));
      await db.softDeleteTransaction('t1');
      final balances = await db.watchBalances(includeArchived: true).first;
      final cash = balances.singleWhere((b) => b.account.id == 'acc-cash');
      expect(cash.balance, 0);
    });
  });

  group('fx rates', () {
    test('manual beats api beats import; nearest earlier date is used', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      var n = 0;
      String newId() => 'fx-${n++}';

      await db.upsertRate(
          date: DateTime.utc(2026, 7, 1),
          usdUgx: 3600,
          source: FxSource.api,
          newId: newId);
      // Import must not overwrite the api row.
      await db.upsertRate(
          date: DateTime.utc(2026, 7, 1),
          usdUgx: 1111,
          source: FxSource.import,
          newId: newId);
      var rate = await db.getRateOn(DateTime.utc(2026, 7, 1));
      expect(rate!.usdUgx, 3600);

      // Manual overwrites api.
      await db.upsertRate(
          date: DateTime.utc(2026, 7, 1),
          usdUgx: 3585,
          source: FxSource.manual,
          newId: newId);
      rate = await db.getRateOn(DateTime.utc(2026, 7, 1));
      expect(rate!.usdUgx, 3585);
      expect(rate.source, FxSource.manual);

      // Nearest earlier date fallback.
      rate = await db.getRateOn(DateTime.utc(2026, 7, 15));
      expect(rate!.usdUgx, 3585);
    });
  });

  group('currency conversion', () {
    FxRate rateRow({double? usdUgx, double? cadUgx}) => FxRate(
          id: 'r',
          date: DateTime.utc(2026, 7, 1),
          usdUgx: usdUgx,
          cadUgx: cadUgx,
          usdCad: null,
          source: FxSource.manual,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          deleted: false,
        );

    test('converts through UGX', () {
      final rate = rateRow(usdUgx: 3600, cadUgx: 2600);
      expect(convertWithRate(3600000, Currency.ugx, Currency.usd, rate), 1000);
      expect(convertWithRate(100, Currency.usd, Currency.ugx, rate), 360000);
      expect(convertWithRate(100, Currency.usd, Currency.cad, rate),
          closeTo(138.46, 0.01));
      expect(convertWithRate(500, Currency.cad, Currency.ugx, rate), 1300000);
    });

    test('returns null when a needed rate is missing', () {
      final rate = rateRow(usdUgx: 3600);
      expect(convertWithRate(100, Currency.cad, Currency.ugx, rate), isNull);
      expect(convertWithRate(100, Currency.usd, Currency.ugx, null), isNull);
      expect(convertWithRate(100, Currency.usd, Currency.usd, null), 100);
    });

    test('FxTable picks latest rate on or before the date', () {
      final rates = [
        FxRate(
          id: 'a',
          date: DateTime.utc(2026, 1, 1),
          usdUgx: 3500,
          cadUgx: null,
          usdCad: null,
          source: FxSource.import,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          deleted: false,
        ),
        FxRate(
          id: 'b',
          date: DateTime.utc(2026, 6, 1),
          usdUgx: 3600,
          cadUgx: null,
          usdCad: null,
          source: FxSource.import,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          deleted: false,
        ),
      ];
      final fx = FxTable(rates);
      expect(fx.rateOn(DateTime.utc(2026, 3, 1))!.usdUgx, 3500);
      expect(fx.rateOn(DateTime.utc(2026, 6, 1))!.usdUgx, 3600);
      expect(fx.rateOn(DateTime.utc(2026, 12, 1))!.usdUgx, 3600);
      // Before all rates: falls back to the earliest.
      expect(fx.rateOn(DateTime.utc(2025, 1, 1))!.usdUgx, 3500);
    });
  });
}
