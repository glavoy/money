import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../shared/providers.dart';
import 'csv_export.dart';

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _saveFile({
    required String fileName,
    required List<String> allowedExtensions,
    required Future<Uint8List> Function() buildBytes,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final bytes = await buildBytes();
      final path = await file_picker.FilePicker.saveFile(
        dialogTitle: 'Save $fileName',
        fileName: fileName,
        type: file_picker.FileType.custom,
        allowedExtensions: allowedExtensions,
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() {
        _message = path == null ? 'Export cancelled.' : 'Saved $fileName.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCsv({
    required String fileName,
    required Future<String> Function() buildContent,
  }) {
    return _saveFile(
      fileName: fileName,
      allowedExtensions: const ['csv'],
      buildBytes: () async => utf8.encode(await buildContent()),
    );
  }

  Future<void> _saveTransactions() {
    return _saveCsv(
      fileName: transactionsExportFileName,
      buildContent: () async {
        final db = ref.read(databaseProvider);
        final ledgerId = ref.read(selectedLedgerProvider);
        final ledgers = await db.getLedgers(includeArchived: true);
        final transactions = await db.getTransactionsForExport(
          ledgerId: ledgerId,
        );
        final accounts = await db.getAccounts(
          ledgerId: ledgerId,
          includeArchived: true,
        );
        final categories = await db.getCategories(
          ledgerId: ledgerId,
          includeArchived: true,
        );
        return transactionsToCsv(
          transactions,
          ledgerNames: {for (final ledger in ledgers) ledger.id: ledger.name},
          accountNames: {
            for (final account in accounts) account.id: account.name,
          },
          categoryNames: {
            for (final category in categories) category.id: category.name,
          },
        );
      },
    );
  }

  Future<void> _saveFxRates() {
    return _saveCsv(
      fileName: fxRatesExportFileName,
      buildContent: () async {
        final rates = await ref.read(databaseProvider).getFxRatesForExport();
        return fxRatesToCsv(rates);
      },
    );
  }

  Future<void> _saveFullExport() {
    final fileName =
        'money_export_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.zip';
    return _saveFile(
      fileName: fileName,
      allowedExtensions: const ['zip'],
      buildBytes: () => buildFullExportZip(ref.read(databaseProvider)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Export everything as a single zip, or download individual CSVs '
            'below (transactions are limited to the selected ledger).',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _saveFullExport,
            icon: const Icon(Icons.folder_zip_outlined),
            label: const Text('Export all data (.zip)'),
          ),
          const Divider(height: 32),
          OutlinedButton.icon(
            onPressed: _busy ? null : _saveTransactions,
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Download transactions.csv'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _saveFxRates,
            icon: const Icon(Icons.currency_exchange_outlined),
            label: const Text('Download fx_rates.csv'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(_message!),
          ],
        ],
      ),
    );
  }
}
