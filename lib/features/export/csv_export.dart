import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';

import '../../data/database.dart';

const transactionsExportFileName = 'transactions.csv';
const fxRatesExportFileName = 'fx_rates.csv';

String transactionsToCsv(
  List<Transaction> transactions, {
  required Map<String, String> ledgerNames,
  required Map<String, String> accountNames,
  required Map<String, String> categoryNames,
}) {
  final rows = <List<Object?>>[
    [
      'id',
      'ledger',
      'date',
      'kind',
      'amount',
      'account',
      'category',
      'to_account',
      'to_amount',
      'note',
    ],
    for (final tx in transactions)
      [
        tx.id,
        ledgerNames[tx.ledgerId] ?? tx.ledgerId,
        _dateOnly(tx.date),
        tx.kind,
        tx.amount,
        accountNames[tx.accountId] ?? tx.accountId,
        tx.categoryId == null
            ? null
            : categoryNames[tx.categoryId] ?? tx.categoryId,
        tx.toAccountId == null
            ? null
            : accountNames[tx.toAccountId] ?? tx.toAccountId,
        tx.toAmount,
        tx.note,
      ],
  ];
  return const CsvEncoder().convert(rows);
}

String ledgersToCsv(List<Ledger> ledgers) {
  final rows = <List<Object?>>[
    ['id', 'name', 'archived', 'sort_order'],
    for (final l in ledgers) [l.id, l.name, l.archived, l.sortOrder],
  ];
  return const CsvEncoder().convert(rows);
}

String accountsToCsv(
  List<Account> accounts, {
  required Map<String, String> ledgerNames,
}) {
  final rows = <List<Object?>>[
    [
      'id',
      'ledger',
      'name',
      'type',
      'currency',
      'opening_balance',
      'opening_date',
      'archived',
      'sort_order',
    ],
    for (final a in accounts)
      [
        a.id,
        ledgerNames[a.ledgerId] ?? a.ledgerId,
        a.name,
        a.type,
        a.currency,
        a.openingBalance,
        a.openingDate == null ? null : _dateOnly(a.openingDate!),
        a.archived,
        a.sortOrder,
      ],
  ];
  return const CsvEncoder().convert(rows);
}

String categoriesToCsv(
  List<Category> categories, {
  required Map<String, String> ledgerNames,
}) {
  final rows = <List<Object?>>[
    ['id', 'ledger', 'name', 'kind', 'sort_order', 'archived'],
    for (final c in categories)
      [
        c.id,
        ledgerNames[c.ledgerId] ?? c.ledgerId,
        c.name,
        c.kind,
        c.sortOrder,
        c.archived,
      ],
  ];
  return const CsvEncoder().convert(rows);
}

String fxRatesToCsv(List<FxRate> rates) {
  final rows = <List<Object?>>[
    ['id', 'date', 'usd_ugx', 'cad_ugx', 'usd_cad', 'source'],
    for (final rate in rates)
      [
        rate.id,
        _dateOnly(rate.date),
        rate.usdUgx,
        rate.cadUgx,
        rate.usdCad,
        rate.source,
      ],
  ];
  return const CsvEncoder().convert(rows);
}

String _dateOnly(DateTime value) {
  final utc = value.toUtc();
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// One CSV per table across every ledger, zipped into a single archive.
Future<Uint8List> buildFullExportZip(AppDatabase db) async {
  final ledgers = await db.getLedgers(includeArchived: true);
  final accounts = await db.getAccounts(includeArchived: true);
  final categories = await db.getCategories(includeArchived: true);
  final transactions = await db.getTransactionsForExport();
  final fxRates = await db.getFxRatesForExport();

  final ledgerNames = {for (final l in ledgers) l.id: l.name};
  final accountNames = {for (final a in accounts) a.id: a.name};
  final categoryNames = {for (final c in categories) c.id: c.name};

  final archive = Archive()
    ..addFile(_csvArchiveFile('ledgers.csv', ledgersToCsv(ledgers)))
    ..addFile(
      _csvArchiveFile(
        'accounts.csv',
        accountsToCsv(accounts, ledgerNames: ledgerNames),
      ),
    )
    ..addFile(
      _csvArchiveFile(
        'categories.csv',
        categoriesToCsv(categories, ledgerNames: ledgerNames),
      ),
    )
    ..addFile(
      _csvArchiveFile(
        'transactions.csv',
        transactionsToCsv(
          transactions,
          ledgerNames: ledgerNames,
          accountNames: accountNames,
          categoryNames: categoryNames,
        ),
      ),
    )
    ..addFile(_csvArchiveFile('fx_rates.csv', fxRatesToCsv(fxRates)));

  return ZipEncoder().encodeBytes(archive);
}

ArchiveFile _csvArchiveFile(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}
