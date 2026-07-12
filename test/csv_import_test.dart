import 'package:drift/native.dart';
import 'package:expense_tracker/data/database.dart';
import 'package:expense_tracker/features/import/csv_import.dart';
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
id,date,usd_ugx,cad_ugx,usd_cad,source
fx-20060101,2006-01-01,1820.0,1564.0,1.1641,import
fx-20060102,2006-01-02,1820.0,1567.0,1.1628,import
''';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('imports transactions, skipping malformed and unknown-account rows', () async {
    final result = await importCsvContent(db, _transactionsCsv);
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
  });

  test('re-importing is idempotent', () async {
    await importCsvContent(db, _transactionsCsv);
    await importCsvContent(db, _transactionsCsv);
    final txs = await db.select(db.transactions).get();
    expect(txs.length, 4);
  });

  test('imports fx rates and keeps the import source', () async {
    final result = await importCsvContent(db, _fxCsv);
    expect(result.kind, 'fx_rates');
    expect(result.imported, 2);
    final rate = await db.getRateOn(DateTime.utc(2006, 1, 1));
    expect(rate!.usdUgx, 1820);
    expect(rate.cadUgx, 1564);
    expect(rate.source, FxSource.import);
  });

  test('unrecognised header is rejected', () async {
    final result = await importCsvContent(db, 'a,b,c\n1,2,3\n');
    expect(result.kind, 'unknown');
    expect(result.imported, 0);
  });
}
