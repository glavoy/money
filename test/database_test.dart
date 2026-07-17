import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/shared/currency.dart';
import 'package:money/sync/sync_service.dart';
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
      final ledgers = await db.getLedgers(includeArchived: true);
      final accounts = await db.getAccounts(includeArchived: true);
      final categories = await db.getCategories(includeArchived: true);
      expect(ledgers.single.name, 'Personal');
      expect(accounts.length, seedAccounts.length);
      expect(
        categories.length,
        seedExpenseCategories.length + seedIncomeCategories.length,
      );
      // History account is archived so it stays out of quick-add.
      expect(
        accounts.singleWhere((a) => a.id == historyAccountId).archived,
        true,
      );
      expect(accounts.every((a) => a.createdAt == seedTimestamp), true);
      expect(accounts.every((a) => a.updatedAt == seedTimestamp), true);
    });

    test(
      'identifies only untouched seed accounts as safe to replace',
      () async {
        final db = _openTestDb();
        addTearDown(db.close);

        final accounts = await db.getAccounts(includeArchived: true);
        final cash = accounts.singleWhere((a) => a.id == 'acc-cash');

        expect(isUntouchedSeedAccount(cash), true);
        expect(
          isUntouchedSeedAccount(cash.copyWith(openingBalance: 100)),
          false,
        );
        expect(
          isUntouchedSeedAccount(
            cash.copyWith(
              updatedAt: seedTimestamp.add(const Duration(seconds: 1)),
            ),
          ),
          false,
        );
        expect(isUntouchedSeedAccount(cash.copyWith(name: 'Wallet')), false);
      },
    );
  });

  group('ledgers', () {
    test('accounts and categories are scoped by ledger', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final now = DateTime.now().toUtc();
      const secondLedgerId = 'ledger-rental';

      await db
          .into(db.ledgers)
          .insert(
            LedgersCompanion.insert(
              id: secondLedgerId,
              name: 'Rental',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              id: 'acc-rental-bank',
              ledgerId: const Value(secondLedgerId),
              name: 'Rental bank',
              type: AccountType.bank,
              currency: 'UGX',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: 'cat-rental-maintenance',
              ledgerId: const Value(secondLedgerId),
              name: 'Maintenance',
              kind: CategoryKind.expense,
              createdAt: now,
              updatedAt: now,
            ),
          );

      final personalAccounts = await db.getAccounts(
        ledgerId: personalLedgerId,
        includeArchived: true,
      );
      final rentalAccounts = await db.getAccounts(
        ledgerId: secondLedgerId,
        includeArchived: true,
      );
      final rentalCategories = await db.getCategories(
        ledgerId: secondLedgerId,
        includeArchived: true,
      );

      expect(personalAccounts.any((a) => a.id == 'acc-rental-bank'), false);
      expect(rentalAccounts.single.name, 'Rental bank');
      expect(rentalCategories.single.name, 'Maintenance');
    });

    test('sync mappers move empty ledger setup between databases', () async {
      final windowsDb = _openTestDb();
      final now = DateTime.now().toUtc();
      const ledgerId = 'ledger-empty-setup';

      await windowsDb
          .into(windowsDb.ledgers)
          .insert(
            LedgersCompanion.insert(
              id: ledgerId,
              name: 'Empty setup',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await windowsDb
          .into(windowsDb.accounts)
          .insert(
            AccountsCompanion.insert(
              id: 'acc-empty-setup',
              ledgerId: const Value(ledgerId),
              name: 'Empty account',
              type: AccountType.bank,
              currency: 'UGX',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await windowsDb
          .into(windowsDb.categories)
          .insert(
            CategoriesCompanion.insert(
              id: 'cat-empty-setup',
              ledgerId: const Value(ledgerId),
              name: 'Empty category',
              kind: CategoryKind.expense,
              createdAt: now,
              updatedAt: now,
            ),
          );

      final exportedRows = <String, List<Map<String, dynamic>>>{};
      for (final table in ['ledgers', 'accounts', 'categories']) {
        final rows = await exportLocalRowsForTest(windowsDb, table);
        exportedRows[table] = rows
            .where(
              (row) => row['ledger_id'] == ledgerId || row['id'] == ledgerId,
            )
            .toList();
      }
      await windowsDb.close();

      final macDb = _openTestDb();
      addTearDown(macDb.close);
      for (final table in ['ledgers', 'accounts', 'categories']) {
        for (final row in exportedRows[table]!) {
          await applyRemoteRowForTest(macDb, table, row);
        }
      }

      expect(
        (await macDb.getLedgers(
          includeArchived: true,
        )).singleWhere((l) => l.id == ledgerId).name,
        'Empty setup',
      );
      expect(
        (await macDb.getAccounts(
          ledgerId: ledgerId,
          includeArchived: true,
        )).single.name,
        'Empty account',
      );
      expect(
        (await macDb.getCategories(
          ledgerId: ledgerId,
          includeArchived: true,
        )).single.name,
        'Empty category',
      );
    });

    test('remote row repairs equal-timestamp local ledger mismatch', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final timestamp = DateTime.utc(2026, 7, 17, 6, 39, 30, 408, 914);
      const ledgerId = 'ledger-target';
      const accountId = 'acc-equal-timestamp';

      await db
          .into(db.ledgers)
          .insert(
            LedgersCompanion.insert(
              id: ledgerId,
              name: 'Target',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              id: accountId,
              ledgerId: const Value(personalLedgerId),
              name: 'Cash',
              type: AccountType.cash,
              currency: 'UGX',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

      await applyRemoteRowForTest(db, 'accounts', {
        'id': accountId,
        'ledger_id': ledgerId,
        'name': 'Cash',
        'type': AccountType.cash,
        'currency': 'UGX',
        'opening_balance': 0,
        'opening_date': null,
        'archived': false,
        'sort_order': 0,
        'created_at': timestamp.toIso8601String(),
        'updated_at': timestamp.toIso8601String(),
        'deleted': false,
      });

      final account = await (db.select(
        db.accounts,
      )..where((a) => a.id.equals(accountId))).getSingle();
      expect(account.ledgerId, ledgerId);
    });
  });

  group('balances', () {
    test('computes opening + income - expense + transfers', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final day = DateTime.utc(2026, 7, 1);

      // Opening balance on cash.
      await (db.update(
        db.accounts,
      )..where((a) => a.id.equals('acc-cash'))).write(
        AccountsCompanion(
          openingBalance: const Value(100000),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

      await db.upsertTransaction(
        _tx(
          id: 't1',
          date: day,
          kind: TxKind.expense,
          amount: 30000,
          accountId: 'acc-cash',
          categoryId: seedCategoryId('food', CategoryKind.expense),
        ),
      );
      await db.upsertTransaction(
        _tx(
          id: 't2',
          date: day,
          kind: TxKind.income,
          amount: 50000,
          accountId: 'acc-cash',
          categoryId: seedCategoryId('Salary', CategoryKind.income),
        ),
      );
      // Currency exchange: $100 -> 360,000 UGX cash.
      await db.upsertTransaction(
        _tx(
          id: 't3',
          date: day,
          kind: TxKind.transfer,
          amount: 100,
          accountId: 'acc-usd-bank',
          toAccountId: 'acc-cash',
          toAmount: 360000,
        ),
      );

      final balances = await db
          .watchBalances(ledgerId: personalLedgerId, includeArchived: true)
          .first;
      final byId = {for (final b in balances) b.account.id: b.balance};
      expect(byId['acc-cash'], 100000 - 30000 + 50000 + 360000);
      expect(byId['acc-usd-bank'], -100);
    });

    test('soft-deleted transactions do not count', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      await db.upsertTransaction(
        _tx(
          id: 't1',
          date: DateTime.utc(2026, 7, 1),
          kind: TxKind.expense,
          amount: 5000,
          accountId: 'acc-cash',
          categoryId: seedCategoryId('food', CategoryKind.expense),
        ),
      );
      await db.softDeleteTransaction('t1');
      final balances = await db
          .watchBalances(ledgerId: personalLedgerId, includeArchived: true)
          .first;
      final cash = balances.singleWhere((b) => b.account.id == 'acc-cash');
      expect(cash.balance, 0);
    });
  });

  group('accounts', () {
    test('unused accounts can be soft-deleted', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final now = DateTime.now().toUtc();

      await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              id: 'acc-unused',
              ledgerId: const Value(personalLedgerId),
              name: 'Unused account',
              type: AccountType.cash,
              currency: 'UGX',
              createdAt: now,
              updatedAt: now,
            ),
          );

      expect(await db.countTransactionsForAccount('acc-unused'), 0);
      expect(await db.softDeleteAccountIfUnused('acc-unused'), true);

      final accounts = await db.getAccounts(
        ledgerId: personalLedgerId,
        includeArchived: true,
      );
      expect(accounts.any((a) => a.id == 'acc-unused'), false);
    });

    test('used accounts cannot be soft-deleted', () async {
      final db = _openTestDb();
      addTearDown(db.close);

      await db.upsertTransaction(
        _tx(
          id: 't1',
          date: DateTime.utc(2026, 7, 1),
          kind: TxKind.expense,
          amount: 5000,
          accountId: 'acc-cash',
          categoryId: seedCategoryId('food', CategoryKind.expense),
        ),
      );

      expect(await db.countTransactionsForAccount('acc-cash'), 1);
      expect(await db.softDeleteAccountIfUnused('acc-cash'), false);

      final accounts = await db.getAccounts(
        ledgerId: personalLedgerId,
        includeArchived: true,
      );
      expect(accounts.any((a) => a.id == 'acc-cash'), true);
    });
  });

  group('categories', () {
    test('unused categories can be soft-deleted', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final now = DateTime.now().toUtc();
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: 'cat-unused',
              name: 'Unused',
              kind: CategoryKind.expense,
              createdAt: now,
              updatedAt: now,
            ),
          );

      expect(await db.countTransactionsForCategory('cat-unused'), 0);
      expect(await db.softDeleteCategoryIfUnused('cat-unused'), true);

      final categories = await db.getCategories(includeArchived: true);
      expect(categories.any((c) => c.id == 'cat-unused'), false);
    });

    test('used categories cannot be soft-deleted', () async {
      final db = _openTestDb();
      addTearDown(db.close);
      final categoryId = seedCategoryId('food', CategoryKind.expense);
      await db.upsertTransaction(
        _tx(
          id: 't1',
          date: DateTime.utc(2026, 7, 1),
          kind: TxKind.expense,
          amount: 5000,
          accountId: 'acc-cash',
          categoryId: categoryId,
        ),
      );

      expect(await db.countTransactionsForCategory(categoryId), 1);
      expect(await db.softDeleteCategoryIfUnused(categoryId), false);

      final categories = await db.getCategories(includeArchived: true);
      expect(categories.any((c) => c.id == categoryId), true);
    });
  });

  group('fx rates', () {
    test(
      'manual beats api beats import; nearest earlier date is used',
      () async {
        final db = _openTestDb();
        addTearDown(db.close);
        var n = 0;
        String newId() => 'fx-${n++}';

        await db.upsertRate(
          date: DateTime.utc(2026, 7, 1),
          usdUgx: 3600,
          source: FxSource.api,
          newId: newId,
        );
        // Import must not overwrite the api row.
        await db.upsertRate(
          date: DateTime.utc(2026, 7, 1),
          usdUgx: 1111,
          source: FxSource.import,
          newId: newId,
        );
        var rate = await db.getRateOn(DateTime.utc(2026, 7, 1));
        expect(rate!.usdUgx, 3600);

        // Manual overwrites api.
        await db.upsertRate(
          date: DateTime.utc(2026, 7, 1),
          usdUgx: 3585,
          source: FxSource.manual,
          newId: newId,
        );
        rate = await db.getRateOn(DateTime.utc(2026, 7, 1));
        expect(rate!.usdUgx, 3585);
        expect(rate.source, FxSource.manual);

        // Nearest earlier date fallback.
        rate = await db.getRateOn(DateTime.utc(2026, 7, 15));
        expect(rate!.usdUgx, 3585);
      },
    );

    test('exact date lookup does not fall back to older rates', () async {
      final db = _openTestDb();
      addTearDown(db.close);

      await db.upsertRate(
        date: DateTime.utc(2026, 7, 1),
        usdUgx: 3600,
        source: FxSource.api,
        newId: () => 'fx-1',
      );

      expect(await db.getRateForDate(DateTime.utc(2026, 7, 1)), isA<FxRate>());
      expect(await db.getRateForDate(DateTime.utc(2026, 7, 2)), isNull);
      expect(await db.getRateOn(DateTime.utc(2026, 7, 2)), isA<FxRate>());
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
      expect(
        convertWithRate(100, Currency.usd, Currency.cad, rate),
        closeTo(138.46, 0.01),
      );
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
