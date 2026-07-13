import 'package:drift/native.dart';
import 'package:money/data/database.dart';
import 'package:money/main.dart';
import 'package:money/shared/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('add an expense through the Quick Add screen', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const ExpenseTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Enter amount.
    await tester.enterText(find.byType(TextField).first, '14500');

    // Pick the 'food' category chip.
    await tester.tap(find.widgetWithText(ChoiceChip, 'food'));
    await tester.pump();

    // Pick the Cash account chip (already default, but tap to be explicit).
    await tester.tap(find.widgetWithText(ChoiceChip, 'Cash'));
    await tester.pump();

    // Save (pinned bottom bar button; label is dynamic so find by key).
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

    // Unmount the tree, then advance the fake clock so drift's zero-duration
    // stream-close timers fire and the test ends with no pending timers.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
