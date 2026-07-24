import 'package:archive/archive.dart';
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
    final ledgers = await db.getLedgers(includeArchived: true);
    final accounts = await db.getAccounts(
      ledgerId: personalLedgerId,
      includeArchived: true,
    );
    final categories = await db.getCategories(
      ledgerId: personalLedgerId,
      includeArchived: true,
    );
    final csv = transactionsToCsv(
      rows,
      ledgerNames: {for (final ledger in ledgers) ledger.id: ledger.name},
      accountNames: {for (final account in accounts) account.id: account.name},
      categoryNames: {
        for (final category in categories) category.id: category.name,
      },
    );

    expect(
      csv,
      contains(
        'id,ledger,date,kind,amount,account,category,to_account,to_amount,'
        'note,exclude_from_report',
      ),
    );
    expect(
      csv,
      contains('tx-1,Personal,2026-07-17,expense,12000.0,Imported history'),
    );
    expect(csv, contains(',"Lunch, with comma",false'));
    expect(csv, contains('food'));
    expect(csv, isNot(contains(historyAccountId)));
    expect(csv, isNot(contains('cat-expense-food')));
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

  test('full export bundles every ledger into one zip', () async {
    final now = DateTime.utc(2026, 7, 17);
    await db
        .into(db.ledgers)
        .insert(
          LedgersCompanion.insert(
            id: 'ledger-rental',
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
            ledgerId: const Value('ledger-rental'),
            name: 'Rental bank',
            type: AccountType.bank,
            currency: 'UGX',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: 'tx-rental',
        ledgerId: const Value('ledger-rental'),
        date: now,
        kind: TxKind.income,
        amount: 500000,
        accountId: 'acc-rental-bank',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: 'tx-personal',
        ledgerId: const Value(personalLedgerId),
        date: now,
        kind: TxKind.expense,
        amount: 12000,
        accountId: historyAccountId,
        categoryId: const Value('cat-expense-food'),
        createdAt: now,
        updatedAt: now,
      ),
    );

    final zipBytes = await buildFullExportZip(db);
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final files = {for (final f in archive) f.name: f};

    expect(
      files.keys,
      containsAll([
        'ledgers.csv',
        'accounts.csv',
        'categories.csv',
        'transactions.csv',
        'fx_rates.csv',
      ]),
    );
    final transactionsCsv = String.fromCharCodes(
      files['transactions.csv']!.content as List<int>,
    );
    // Both ledgers' transactions are present, each tagged with its ledger.
    expect(transactionsCsv, contains('tx-rental,Rental'));
    expect(transactionsCsv, contains('tx-personal,Personal'));
    final ledgersCsv = String.fromCharCodes(
      files['ledgers.csv']!.content as List<int>,
    );
    expect(ledgersCsv, contains('Rental'));
    expect(ledgersCsv, contains('Personal'));
  });
}
