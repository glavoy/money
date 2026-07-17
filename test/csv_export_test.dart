import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/features/export/csv_export.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('exports active transactions for the selected ledger', () async {
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: 'tx-1',
        ledgerId: const Value(personalLedgerId),
        date: DateTime.utc(2026, 7, 17),
        kind: TxKind.expense,
        amount: 12000,
        accountId: historyAccountId,
        categoryId: const Value('cat-expense-food'),
        note: const Value('Lunch, with comma'),
        createdAt: DateTime.utc(2026, 7, 17, 8),
        updatedAt: DateTime.utc(2026, 7, 17, 8),
      ),
    );
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: 'tx-other-ledger',
        ledgerId: const Value('other-ledger'),
        date: DateTime.utc(2026, 7, 17),
        kind: TxKind.income,
        amount: 1,
        accountId: historyAccountId,
        createdAt: DateTime.utc(2026, 7, 17, 8),
        updatedAt: DateTime.utc(2026, 7, 17, 8),
      ),
    );
    await db.softDeleteTransaction('tx-other-ledger');

    final rows = await db.getTransactionsForExport(ledgerId: personalLedgerId);
    final csv = transactionsToCsv(rows);

    expect(
      csv,
      contains(
        'id,date,kind,amount,account_id,category_id,to_account_id,to_amount,note',
      ),
    );
    expect(csv, contains('tx-1,2026-07-17,expense,12000.0'));
    expect(csv, contains('"Lunch, with comma"'));
    expect(csv, isNot(contains('tx-other-ledger')));
  });

  test('exports active fx rates', () async {
    await db.upsertRate(
      date: DateTime.utc(2026, 7, 17),
      usdUgx: 3600,
      cadUgx: 2600,
      usdCad: 1.38,
      source: FxSource.manual,
      newId: () => 'fx-1',
    );
    await db
        .into(db.fxRates)
        .insert(
          FxRatesCompanion.insert(
            id: 'fx-deleted',
            date: DateTime.utc(2026, 7, 18),
            source: const Value(FxSource.import),
            createdAt: DateTime.utc(2026, 7, 18),
            updatedAt: DateTime.utc(2026, 7, 18),
            deleted: const Value(true),
          ),
        );

    final csv = fxRatesToCsv(await db.getFxRatesForExport());

    expect(csv, contains('id,date,usd_ugx,cad_ugx,usd_cad,source'));
    expect(csv, contains('fx-1,2026-07-17,3600.0,2600.0,1.38,manual'));
    expect(csv, isNot(contains('fx-deleted')));
  });
}
