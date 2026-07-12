import 'package:csv/csv.dart';
import 'package:drift/drift.dart' show InsertMode, Value;

import '../../data/database.dart';

class ImportResult {
  ImportResult(this.kind, this.imported, this.skipped);

  final String kind; // 'transactions' | 'fx_rates' | 'unknown'
  final int imported;
  final int skipped;
}

/// Imports one CSV file's content (from tools/import_xlsx.py). The file type
/// is detected from the header row. Rows with unknown accounts/categories or
/// unparseable values are counted as skipped. Idempotent: rows are keyed by
/// their id and overwrite themselves on re-import.
Future<ImportResult> importCsvContent(
  AppDatabase db,
  String content, {
  void Function(int done)? onProgress,
}) async {
  final rows = const CsvDecoder().convert(content);
  if (rows.isEmpty) return ImportResult('unknown', 0, 0);
  final header = [for (final h in rows.first) h.toString().trim()];
  if (header.contains('kind') && header.contains('account_id')) {
    return _importTransactions(db, header, rows.skip(1), onProgress);
  }
  if (header.contains('usd_ugx')) {
    return _importFxRates(db, header, rows.skip(1), onProgress);
  }
  return ImportResult('unknown', 0, 0);
}

String? _cell(Map<String, int> col, List row, String name) {
  final i = col[name];
  if (i == null || i >= row.length) return null;
  final v = row[i].toString().trim();
  return v.isEmpty ? null : v;
}

Future<ImportResult> _importTransactions(
  AppDatabase db,
  List<String> header,
  Iterable<List> rows,
  void Function(int done)? onProgress,
) async {
  final col = {for (var i = 0; i < header.length; i++) header[i]: i};
  final now = DateTime.now().toUtc();
  final accountIds = {
    for (final a in await db.getAccounts(includeArchived: true)) a.id,
  };
  final categoryIds = {
    for (final c in await db.getCategories(includeArchived: true)) c.id,
  };

  var imported = 0, skipped = 0;
  final pending = <TransactionsCompanion>[];

  Future<void> flush() async {
    if (pending.isEmpty) return;
    final copy = List.of(pending);
    pending.clear();
    await db.batch((b) {
      for (final r in copy) {
        b.insert(db.transactions, r, mode: InsertMode.insertOrReplace);
      }
    });
    onProgress?.call(imported);
  }

  for (final row in rows) {
    final id = _cell(col, row, 'id');
    final dateRaw = _cell(col, row, 'date');
    final kind = _cell(col, row, 'kind');
    final amountRaw = _cell(col, row, 'amount');
    final accountId = _cell(col, row, 'account_id');
    final categoryId = _cell(col, row, 'category_id');
    final date = dateRaw == null ? null : DateTime.tryParse(dateRaw);
    final amount = amountRaw == null ? null : double.tryParse(amountRaw);
    if (id == null ||
        date == null ||
        kind == null ||
        amount == null ||
        accountId == null ||
        !accountIds.contains(accountId) ||
        (categoryId != null && !categoryIds.contains(categoryId))) {
      skipped++;
      continue;
    }
    pending.add(
      TransactionsCompanion.insert(
        id: id,
        date: DateTime.utc(date.year, date.month, date.day),
        kind: kind,
        amount: amount,
        accountId: accountId,
        categoryId: Value(categoryId),
        toAccountId: Value(_cell(col, row, 'to_account_id')),
        toAmount: Value(double.tryParse(_cell(col, row, 'to_amount') ?? '')),
        note: Value(_cell(col, row, 'note')),
        createdAt: now,
        updatedAt: now,
      ),
    );
    imported++;
    if (pending.length >= 2000) await flush();
  }
  await flush();
  return ImportResult('transactions', imported, skipped);
}

Future<ImportResult> _importFxRates(
  AppDatabase db,
  List<String> header,
  Iterable<List> rows,
  void Function(int done)? onProgress,
) async {
  final col = {for (var i = 0; i < header.length; i++) header[i]: i};
  final now = DateTime.now().toUtc();

  var imported = 0, skipped = 0;
  final pending = <FxRatesCompanion>[];

  Future<void> flush() async {
    if (pending.isEmpty) return;
    final copy = List.of(pending);
    pending.clear();
    await db.batch((b) {
      for (final r in copy) {
        b.insert(db.fxRates, r, mode: InsertMode.insertOrReplace);
      }
    });
    onProgress?.call(imported);
  }

  for (final row in rows) {
    final id = _cell(col, row, 'id');
    final dateRaw = _cell(col, row, 'date');
    final date = dateRaw == null ? null : DateTime.tryParse(dateRaw);
    if (id == null || date == null) {
      skipped++;
      continue;
    }
    pending.add(
      FxRatesCompanion.insert(
        id: id,
        date: DateTime.utc(date.year, date.month, date.day),
        usdUgx: Value(double.tryParse(_cell(col, row, 'usd_ugx') ?? '')),
        cadUgx: Value(double.tryParse(_cell(col, row, 'cad_ugx') ?? '')),
        usdCad: Value(double.tryParse(_cell(col, row, 'usd_cad') ?? '')),
        source: Value(_cell(col, row, 'source') ?? FxSource.import),
        createdAt: now,
        updatedAt: now,
      ),
    );
    imported++;
    if (pending.length >= 2000) await flush();
  }
  await flush();
  return ImportResult('fx_rates', imported, skipped);
}
