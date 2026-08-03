import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/main.dart';
import 'package:money/shared/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppDatabase> pumpApp(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        autoFetchTodayRateProvider.overrideWithValue(false),
      ],
      child: const ExpenseTrackerApp(),
    ),
  );
  await tester.pumpAndSettle();
  return db;
}

Future<void> tearDownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
    'History shows the true currency for a transaction on an archived '
    'import account, not UGX',
    (tester) async {
      final db = await pumpApp(tester);
      final now = DateTime.now().toUtc();

      // Mirrors what importHistoricalUsdIncomeCsv creates: a dedicated,
      // archived USD account holding historical income.
      await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              id: 'acc-import-usd',
              ledgerId: const Value(personalLedgerId),
              name: 'Imported history USD',
              type: AccountType.cash,
              currency: 'USD',
              archived: const Value(true),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db.upsertTransaction(
        TransactionsCompanion.insert(
          id: 'imp-inc-usd-test',
          ledgerId: const Value(personalLedgerId),
          date: DateTime.utc(2020, 6, 1),
          kind: TxKind.income,
          amount: 500,
          accountId: 'acc-import-usd',
          categoryId: const Value('cat-income-salary'),
          note: const Value('Historical USD income'),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await tester.pump();

      // History is the landing tab, so no navigation needed.
      // The archived import date (2020) is outside the default recent-months
      // filter, so switch to all-time before the entry becomes visible.
      await tester.tap(find.text('Last 12 months'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All history'));
      await tester.pumpAndSettle();

      expect(find.textContaining('500.00 USD'), findsOneWidget);
      expect(find.textContaining('500 UGX'), findsNothing);

      await tearDownTree(tester);
    },
  );

  testWidgets(
    'editing a USD transaction pre-fills the real amount, not a rounded one',
    (tester) async {
      final db = await pumpApp(tester);
      final now = DateTime.now().toUtc();

      await db.upsertTransaction(
        TransactionsCompanion.insert(
          id: 'tx-usd-cents',
          ledgerId: const Value(personalLedgerId),
          date: DateTime.utc(now.year, now.month, now.day),
          kind: TxKind.expense,
          amount: 165.99,
          accountId: 'acc-visa',
          categoryId: const Value('cat-expense-food'),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('165.99'));
      await tester.pumpAndSettle();

      // The sheet's keypad display carries the full stored precision.
      final display = tester.widget<Text>(
        find.byKey(const ValueKey('amount-display')),
      );
      expect(display.data, '−165.99 USD');

      await tearDownTree(tester);
    },
  );

  testWidgets(
    'History names both sides of a cross-ledger transfer, qualifying the '
    'account in the other ledger with its ledger name',
    (tester) async {
      final db = await pumpApp(tester);
      final now = DateTime.now().toUtc();

      await db
          .into(db.ledgers)
          .insert(
            LedgersCompanion.insert(
              id: 'led-invest',
              name: 'Investments',
              // Not 0: that ties with Personal on sort order and wins on
              // name, which would make Investments the selected ledger.
              sortOrder: const Value(1),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              id: 'acc-uap',
              ledgerId: const Value('led-invest'),
              name: 'UAP',
              type: AccountType.bank,
              currency: 'UGX',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db.upsertTransaction(
        TransactionsCompanion.insert(
          id: 'tx-cross-ledger',
          ledgerId: const Value(personalLedgerId),
          date: DateTime.utc(now.year, now.month, now.day),
          kind: TxKind.transfer,
          amount: 1250000,
          accountId: 'acc-cash',
          toAccountId: const Value('acc-uap'),
          toAmount: const Value(1250000),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await tester.pumpAndSettle();

      // Regression: the destination lives outside the selected ledger, so
      // resolving it from the current ledger's accounts rendered it as "?".
      expect(find.text('Cash → Investments · UAP'), findsOneWidget);
      expect(find.textContaining('?'), findsNothing);

      await tearDownTree(tester);
    },
  );
}
