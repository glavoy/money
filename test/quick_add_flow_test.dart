import 'package:drift/native.dart';
import 'package:money/data/database.dart';
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

/// Unmount the tree, then advance the fake clock so drift's zero-duration
/// stream-close timers fire and the test ends with no pending timers.
Future<void> tearDownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('add an expense through the Quick Add screen', (tester) async {
    final db = await pumpApp(tester);

    // Enter amount.
    await tester.enterText(find.byType(TextField).first, '14500');

    // Pick the 'food' category chip (top of the quick chips: with no usage
    // history the ranking falls back to seed sort order).
    await tester.tap(find.widgetWithText(ChoiceChip, 'food'));
    await tester.pump();

    // Pick the Cash account through the account selector sheet.
    await tester.tap(find.byKey(const ValueKey('account-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Cash'));
    await tester.pumpAndSettle();

    // Save (compact button next to the amount field).
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    // The day summary shows the new entry.
    expect(find.text('food'), findsWidgets);
    expect(find.textContaining('14,500'), findsWidgets);

    // And it landed in the database. (Plain select inside runAsync: drift
    // stream emissions use Timer.run, which never fires on the fake clock.)
    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.length, 1);
    expect(txs.single.amount, 14500);
    expect(txs.single.kind, TxKind.expense);
    expect(txs.single.accountId, 'acc-cash');

    await tearDownTree(tester);
  });

  testWidgets('step back a day with the arrow and save to yesterday', (
    tester,
  ) async {
    final db = await pumpApp(tester);

    // Step back one day; the label switches to Yesterday.
    await tester.tap(find.byKey(const ValueKey('date-back')));
    await tester.pump();
    expect(find.text('Yesterday'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '2000');
    await tester.tap(find.widgetWithText(ChoiceChip, 'beer'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final yesterday = DateTime.utc(now.year, now.month, now.day - 1);
    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.amount, 2000);
    expect(txs.single.date, yesterday);

    // The forward arrow returns to today, then disables.
    await tester.tap(find.byKey(const ValueKey('date-forward')));
    await tester.pump();
    expect(find.text('Today'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('date-forward')))
          .onPressed,
      isNull,
    );

    await tearDownTree(tester);
  });

  testWidgets('pick a lower-ranked category from the All sheet', (
    tester,
  ) async {
    final db = await pumpApp(tester);

    // 'guard' is seeded past the quick-chip cutoff, so it is only reachable
    // through the All sheet.
    expect(find.widgetWithText(ChoiceChip, 'guard'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('category-more')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('category-search')),
      'gua',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'guard'));
    await tester.pumpAndSettle();

    // The selected category is now visible among the quick chips.
    expect(find.widgetWithText(ChoiceChip, 'guard'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '5000');
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.categoryId, 'cat-expense-guard');

    await tearDownTree(tester);
  });
}
