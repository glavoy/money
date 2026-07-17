import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:money/data/database.dart';
import 'package:money/data/seed.dart';
import 'package:money/features/import/csv_import.dart';
import 'package:flutter_test/flutter_test.dart';

// Rows in exactly the format tools/import_xlsx.py produces.
const _transactionsCsv = '''
id,date,kind,amount,account_id,category_id,to_account_id,to_amount,note
imp-20060101-food,2006-01-01,expense,3000.0,acc-history,cat-expense-food,,,
imp-20060101-car,2006-01-01,expense,12000.0,acc-history,cat-expense-car,,,Tube-12000
imp-20060105-bigticket,2006-01-05,expense,400000.0,acc-history,cat-expense-bigticket,,,House in Busiga
imp-inc-200601,2006-01-01,income,3650000.0,acc-history,cat-income-salary,,,
bad-row,not-a-date,expense,10,acc-history,cat-expense-food,,,
unknown-account,2006-01-02,expense,10,acc-nope,cat-expense-food,,,
''';

const _fxCsv = '''
date,usd_ugx,cad_ugx,usd_cad
2006-01-01,1820.0,1564.0,1.1641
2006-01-02,1820.0,1567.0,1.1628
''';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'imports transactions, skipping malformed and unknown-account rows',
    () async {
      final result = await importCsvContent(
        db,
        _transactionsCsv,
        ledgerId: personalLedgerId,
      );
      expect(result.kind, 'transactions');
      expect(result.imported, 4);
      expect(result.skipped, 2);

      final txs = await db.select(db.transactions).get();
      expect(txs.length, 4);
      final food = txs.singleWhere((t) => t.id == 'imp-20060101-food');
      expect(food.amount, 3000);
      expect(food.date, DateTime.utc(2006, 1, 1));
      expect(food.kind, TxKind.expense);
      final car = txs.singleWhere((t) => t.id == 'imp-20060101-car');
      expect(car.note, 'Tube-12000');
      final income = txs.singleWhere((t) => t.id == 'imp-inc-200601');
      expect(income.kind, TxKind.income);
      expect(income.amount, 3650000);
    },
  );

  test('re-importing is idempotent', () async {
    await importCsvContent(db, _transactionsCsv, ledgerId: personalLedgerId);
    await importCsvContent(db, _transactionsCsv, ledgerId: personalLedgerId);
    final txs = await db.select(db.transactions).get();
    expect(txs.length, 4);
  });

  test('imports fx rates from date-keyed csv and generates metadata', () async {
    final result = await importCsvContent(
      db,
      _fxCsv,
      ledgerId: personalLedgerId,
    );
    expect(result.kind, 'fx_rates');
    expect(result.imported, 2);
    final rate = await db.getRateOn(DateTime.utc(2006, 1, 1));
    expect(rate!.usdUgx, 1820);
    expect(rate.cadUgx, 1564);
    expect(rate.source, FxSource.import);
    expect(rate.id, isNotEmpty);
    expect(rate.deleted, isFalse);
  });

  test(
    'fx import overwrites matching dates and leaves other dates alone',
    () async {
      await db
          .into(db.fxRates)
          .insert(
            FxRatesCompanion.insert(
              id: 'existing-rate',
              date: DateTime.utc(2006, 1, 1),
              usdUgx: const Value(1),
              cadUgx: const Value(2),
              usdCad: const Value(3),
              source: const Value(FxSource.manual),
              createdAt: DateTime.utc(2000),
              updatedAt: DateTime.utc(2000),
              deleted: const Value(true),
            ),
          );
      await db
          .into(db.fxRates)
          .insert(
            FxRatesCompanion.insert(
              id: 'untouched-rate',
              date: DateTime.utc(2006, 1, 3),
              usdUgx: const Value(9),
              cadUgx: const Value(8),
              usdCad: const Value(7),
              source: const Value(FxSource.manual),
              createdAt: DateTime.utc(2000),
              updatedAt: DateTime.utc(2000),
            ),
          );

      final result = await importCsvContent(
        db,
        _fxCsv,
        ledgerId: personalLedgerId,
      );

      expect(result.imported, 2);
      final overwritten = await db.getRateOn(DateTime.utc(2006, 1, 1));
      expect(overwritten!.id, 'existing-rate');
      expect(overwritten.usdUgx, 1820);
      expect(overwritten.cadUgx, 1564);
      expect(overwritten.usdCad, 1.1641);
      expect(overwritten.source, FxSource.import);
      expect(overwritten.deleted, isFalse);

      final untouched = await (db.select(
        db.fxRates,
      )..where((r) => r.id.equals('untouched-rate'))).getSingle();
      expect(untouched.usdUgx, 9);
      expect(untouched.source, FxSource.manual);
      expect(untouched.deleted, isFalse);
    },
  );

  test('unrecognised header is rejected', () async {
    final result = await importCsvContent(
      db,
      'a,b,c\n1,2,3\n',
      ledgerId: personalLedgerId,
    );
    expect(result.kind, 'unknown');
    expect(result.imported, 0);
  });
}
