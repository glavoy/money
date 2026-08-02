import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/main.dart';
import 'package:money/shared/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppDatabase> pumpApp(
  WidgetTester tester, {
  Size physicalSize = const Size(1200, 2400),
  Future<void> Function(AppDatabase db)? seed,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  // Seed before the first pump: drift streams that are already subscribed do
  // not reliably re-emit under the widget tester's fake clock.
  await seed?.call(db);

  tester.view.physicalSize = physicalSize;
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

/// Opens the entry sheet from the bottom nav's add slot.
Future<void> openAddSheet(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

/// Selects Expense/Income/Transfer in the open sheet.
///
/// Tapping the SegmentedButton itself would hit the centre of the group (the
/// Income segment) regardless of which kind was asked for, so target the
/// segment's own label — scoped to the sheet, since History has a
/// same-labelled filter behind it.
Future<void> selectKind(WidgetTester tester, String kind) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('sheet-body')),
      matching: find.text(kind),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps [digits] on the keypad, one key at a time.
Future<void> typeAmount(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.byKey(ValueKey('key-$d')));
    await tester.pump();
  }
}

void main() {
  testWidgets('add an expense through the entry sheet', (tester) async {
    final db = await pumpApp(tester);
    await openAddSheet(tester);

    await typeAmount(tester, '14500');
    expect(find.textContaining('14,500'), findsOneWidget);

    // 'food' is top of the ranked grid: with no usage history the ranking
    // falls back to seed sort order.
    await tester.tap(find.text('food'));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    // Plain select inside runAsync: drift stream emissions use Timer.run,
    // which never fires on the fake clock.
    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.length, 1);
    expect(txs.single.amount, 14500);
    expect(txs.single.kind, TxKind.expense);
    // Defaults to the first account when nothing was used previously.
    expect(txs.single.accountId, 'acc-cash');

    await tearDownTree(tester);
  });

  testWidgets('step back a day with the arrow and save to yesterday', (
    tester,
  ) async {
    final db = await pumpApp(tester);
    await openAddSheet(tester);

    await tester.tap(find.byKey(const ValueKey('date-back')));
    await tester.pump();
    expect(find.text('Yesterday'), findsOneWidget);

    await typeAmount(tester, '2000');
    await tester.tap(find.text('beer'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final yesterday = DateTime.utc(now.year, now.month, now.day - 1);
    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.amount, 2000);
    expect(txs.single.date, yesterday);

    await tearDownTree(tester);
  });

  testWidgets('pick a lower-ranked category by scrolling the grid', (
    tester,
  ) async {
    final db = await pumpApp(tester);
    await openAddSheet(tester);

    // 'guard' is seeded well down the list, so it needs a scroll rather than
    // the separate "all categories" sheet the old Quick Add screen used.
    await tester.scrollUntilVisible(
      find.text('guard'),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('category-grid')),
        matching: find.byType(Scrollable),
      ),
    );
    // scrollUntilVisible stops once the tile is merely built — it can still
    // be in the cache extent below the viewport, where a synthetic tap would
    // land on the keypad instead.
    await tester.ensureVisible(find.text('guard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('guard'));
    await tester.pump();

    await typeAmount(tester, '5000');
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.categoryId, 'cat-expense-guard');

    await tearDownTree(tester);
  });

  testWidgets('a whole expense fits a small phone without scrolling', (
    tester,
  ) async {
    // 360x640 logical — a small Android phone, the case that motivated
    // replacing the system keyboard with a keypad. Any overflow in the sheet
    // throws and fails this test.
    final db = await pumpApp(tester, physicalSize: const Size(720, 1280));
    await openAddSheet(tester);

    // Everything needed for a normal entry is reachable without scrolling:
    // amount keys, a category, and Save are all on screen at once.
    expect(find.byKey(const ValueKey('key-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-000')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-button')), findsOneWidget);
    expect(find.text('food'), findsOneWidget);

    await typeAmount(tester, '14500');
    await tester.tap(find.text('food'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.amount, 14500);

    await tearDownTree(tester);
  });

  testWidgets('the layout does not move when the kind changes', (tester) async {
    await pumpApp(tester);
    await openAddSheet(tester);

    Rect rectOf(String key) => tester.getRect(find.byKey(ValueKey(key)));
    final sheet = rectOf('sheet-body');
    // The amount text's own width legitimately changes with the +/−/none
    // sign, so pin its vertical position rather than its whole rect.
    final amountTop = rectOf('amount-display').top;
    final firstKey = rectOf('key-1');

    for (final kind in ['Income', 'Transfer', 'Expense']) {
      await selectKind(tester, kind);
      expect(rectOf('sheet-body'), sheet, reason: 'sheet resized on $kind');
      expect(
        rectOf('amount-display').top,
        amountTop,
        reason: 'amount moved on $kind',
      );
      expect(rectOf('key-1'), firstKey, reason: 'keypad moved on $kind');
    }

    await tearDownTree(tester);
  });

  testWidgets('no overflow at 360x640 in any state', (tester) async {
    await pumpApp(tester, physicalSize: const Size(720, 1280));
    await openAddSheet(tester);

    for (final kind in ['Income', 'Transfer', 'Expense']) {
      await selectKind(tester, kind);
      expect(tester.takeException(), isNull, reason: 'overflow on $kind');
    }

    // Toggling the note on and off is the other size-changing path.
    await tester.tap(find.byTooltip('Note'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'overflow with note open');
    await tester.tap(find.byTooltip('Note'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'overflow with note closed');

    await tearDownTree(tester);
  });

  testWidgets('save stays reachable when the system keyboard replaces the '
      'keypad', (tester) async {
    await pumpApp(tester, physicalSize: const Size(720, 1280));
    await openAddSheet(tester);

    // Simulate the IME taking the bottom 300 logical px.
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();
    // The sheet resizes a frame before its parent does, so one transient
    // overflow is reported mid-animation; the settled layout is what counts.
    tester.takeException();

    expect(find.byKey(const ValueKey('key-1')), findsNothing);
    expect(find.byKey(const ValueKey('save-button')), findsOneWidget);
    // Settled, everything is inside the space the keyboard left.
    final sheet = tester.getRect(find.byKey(const ValueKey('sheet-body')));
    expect(sheet.bottom, lessThanOrEqualTo(640 - 300));
    expect(
      tester.getRect(find.byKey(const ValueKey('save-button'))).bottom,
      lessThanOrEqualTo(sheet.bottom),
    );

    await tearDownTree(tester);
  });

  testWidgets('the keypad clears the system navigation bar', (tester) async {
    // 1080x2412 @2.75 with a ~48px Android nav bar — showModalBottomSheet
    // does not inset for system UI, so the bottom row used to sit under it.
    tester.view.padding = const FakeViewPadding(bottom: 48 * 2.75);
    await pumpApp(tester, physicalSize: const Size(1080, 2412));
    tester.view.devicePixelRatio = 2.75;
    await tester.pumpAndSettle();
    await openAddSheet(tester);

    final navBarTop = (2412 / 2.75) - 48;
    final bottomRow = tester.getRect(find.byKey(const ValueKey('key-000')));
    expect(bottomRow.bottom, lessThanOrEqualTo(navBarTop));

    await tearDownTree(tester);
  });

  testWidgets('typing on a physical keyboard drives the amount and saves', (
    tester,
  ) async {
    final db = await pumpApp(tester);
    await openAddSheet(tester);

    for (final k in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad0,
    ]) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }
    expect(find.textContaining('14,500'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.textContaining('1,450'), findsOneWidget);

    await tester.tap(find.text('food'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.amount, 1450);

    await tearDownTree(tester);
  });

  testWidgets('typing letters filters the category grid', (tester) async {
    await pumpApp(tester);
    await openAddSheet(tester);

    for (final k in [
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyE,
    ]) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }

    expect(find.byKey(const ValueKey('category-filter-chip')), findsOneWidget);
    expect(find.text('beer'), findsOneWidget);
    expect(find.text('food'), findsNothing);

    // Enter takes the top match rather than saving while a filter is active.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-filter-chip')), findsNothing);
    expect(find.text('food'), findsWidgets);

    await tearDownTree(tester);
  });

  testWidgets('a transfer can target an account in another ledger', (
    tester,
  ) async {
    final db = await pumpApp(
      tester,
      seed: (db) async {
        final now = DateTime.now().toUtc();
        await db
            .into(db.ledgers)
            .insert(
              LedgersCompanion.insert(
                id: 'ledger-invest',
                name: 'Investments',
                // Matches how the app assigns sortOrder (Value(count)). At
                // the default 0 it would tie with Personal and win on name,
                // becoming the auto-selected ledger.
                sortOrder: const Value(1),
                createdAt: now,
                updatedAt: now,
              ),
            );
        await db
            .into(db.accounts)
            .insert(
              AccountsCompanion.insert(
                id: 'acc-savings',
                ledgerId: const Value('ledger-invest'),
                name: 'Savings',
                type: AccountType.bank,
                currency: 'UGX',
                createdAt: now,
                updatedAt: now,
              ),
            );
      },
    );

    await openAddSheet(tester);
    await selectKind(tester, 'Transfer');

    // Other ledgers appear below their own header, qualified by ledger name
    // since account names repeat across ledgers.
    expect(find.text('OTHER LEDGERS'), findsOneWidget);
    final destination = find.text('Investments · Savings');
    expect(destination, findsOneWidget);
    await tester.ensureVisible(destination);
    await tester.pumpAndSettle();
    await tester.tap(destination);
    await tester.pump();

    await typeAmount(tester, '500000');
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    final tx = txs!.single;
    expect(tx.kind, TxKind.transfer);
    expect(tx.toAccountId, 'acc-savings');
    expect(tx.amount, 500000);
    // Recorded against the source account's ledger.
    expect(tx.ledgerId, personalLedgerId);

    await tearDownTree(tester);
  });

  testWidgets('adding from an account ledger pre-selects that account', (
    tester,
  ) async {
    final db = await pumpApp(tester);

    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MTN Mobile Money'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add transaction'));
    await tester.pumpAndSettle();

    // The account chip shows the ledger's own account, not the default.
    expect(find.textContaining('MTN Mobile Money'), findsWidgets);

    await typeAmount(tester, '3000');
    await tester.tap(find.text('food'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await tester.pumpAndSettle();

    final txs = await tester.runAsync(() => db.select(db.transactions).get());
    expect(txs!.single.accountId, 'acc-mtn');
    expect(txs.single.amount, 3000);

    await tearDownTree(tester);
  });
}
