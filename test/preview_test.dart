// Visual previews: renders each screen at phone size and writes PNGs to
// test/goldens/. Not a regression test — regenerate whenever you want to
// eyeball the UI:
//
//   flutter test test/preview_test.dart --update-goldens
//
@Tags(['preview'])
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/main.dart';
import 'package:money/shared/providers.dart';

Future<void> _loadRealFonts() async {
  // FLUTTER_ROOT when set, else derived from the Dart executable inside the
  // SDK (…/flutter/bin/cache/dart-sdk/bin/dart.exe).
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent // bin
          .parent // dart-sdk
          .parent // cache
          .parent // bin
          .parent // flutter
          .path;
  final dir = Directory('$flutterRoot/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  final loader = FontLoader('Roboto');
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last.toLowerCase();
    if (name.startsWith('roboto-') && name.endsWith('.ttf')) {
      loader.addFont(
        f.readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
      );
    }
  }
  await loader.load();
}

Future<AppDatabase> _sampleDb() async {
  final db = AppDatabase(NativeDatabase.memory());
  final now = DateTime.now().toUtc();
  final today = DateTime.utc(now.year, now.month, now.day);
  await db.upsertRate(
    date: today,
    usdUgx: 3560,
    cadUgx: 2620,
    usdCad: 1.36,
    source: FxSource.api,
    newId: () => 'fx-preview',
  );
  Future<void> tx(String id, int daysAgo, String kind, double amount,
      String account, String? category,
      {String? note, String? toAccount, double? toAmount}) async {
    await db.upsertTransaction(TransactionsCompanion.insert(
      id: id,
      date: today.subtract(Duration(days: daysAgo)),
      kind: kind,
      amount: amount,
      accountId: account,
      categoryId: Value(category),
      toAccountId: Value(toAccount),
      toAmount: Value(toAmount),
      note: Value(note),
      createdAt: now,
      updatedAt: now,
    ));
  }

  String cat(String name) => seedCategoryId(name, CategoryKind.expense);
  await tx('p1', 0, TxKind.expense, 44700, 'acc-cash', cat('food'));
  await tx('p2', 0, TxKind.expense, 66100, 'acc-mtn', cat('food_r'),
      note: 'Glovo lunch');
  await tx('p3', 0, TxKind.expense, 25000, 'acc-cash', cat('beer'));
  await tx('p4', 1, TxKind.expense, 151000, 'acc-airtel', cat('petrol'));
  await tx('p5', 1, TxKind.expense, 238300, 'acc-stanbic', cat('guard'),
      note: 'Ultimate Security, June');
  await tx('p6', 2, TxKind.expense, 62650, 'acc-cash', cat('water'));
  await tx('p7', 2, TxKind.expense, 12000, 'acc-cash', cat('motorcycle'));
  await tx('p8', 3, TxKind.expense, 89.5, 'acc-visa', cat('recreation'),
      note: 'Netflix + Spotify');
  await tx('p9', 1, TxKind.income, 1250000, 'acc-stanbic',
      seedCategoryId('Rent income', CategoryKind.income), note: 'Buziga');
  await tx('p10', 4, TxKind.transfer, 2000, 'acc-usd-bank', null,
      toAccount: 'acc-cash', toAmount: 7120000, note: r'Changed $2000 @ 3560');
  await tx('p11', 5, TxKind.expense, 203000, 'acc-mtn', cat('electricity'));
  await tx('p12', 6, TxKind.expense, 130000, 'acc-cash', cat('house'));
  return db;
}

void main() {
  setUpAll(_loadRealFonts);

  Future<void> preview(WidgetTester tester, AppDatabase db, int tabIndex,
      String goldenName) async {
    tester.view.physicalSize = const Size(412 * 2, 915 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const ExpenseTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    if (tabIndex > 0) {
      await tester.tap(find.byType(NavigationDestination).at(tabIndex));
      // Bounded pumps instead of pumpAndSettle: the Reports tab shows an
      // indeterminate spinner while its FutureBuilder resolves, which would
      // keep pumpAndSettle from ever settling.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$goldenName.png'),
    );
    // Unmount and flush drift's stream-close timers.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  for (final (index, name) in [
    (0, 'add'),
    (1, 'history'),
    (2, 'accounts'),
    (3, 'reports'),
    (4, 'settings'),
  ]) {
    testWidgets('preview $name', (tester) async {
      final db = await tester.runAsync(_sampleDb);
      addTearDown(db!.close);
      await preview(tester, db, index, name);
    });
  }
}
