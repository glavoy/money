import 'package:csv/csv.dart';

import '../../data/database.dart';

const transactionsExportFileName = 'transactions.csv';
const fxRatesExportFileName = 'fx_rates.csv';

String transactionsToCsv(List<Transaction> transactions) {
  final rows = <List<Object?>>[
    [
      'id',
      'date',
      'kind',
      'amount',
      'account_id',
      'category_id',
      'to_account_id',
      'to_amount',
      'note',
    ],
    for (final tx in transactions)
      [
        tx.id,
        _dateOnly(tx.date),
        tx.kind,
        tx.amount,
        tx.accountId,
        tx.categoryId,
        tx.toAccountId,
        tx.toAmount,
        tx.note,
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
