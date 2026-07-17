import 'dart:convert';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Future<void> _saveCsv({
    required String fileName,
    required Future<String> Function() buildContent,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final content = await buildContent();
      final path = await file_picker.FilePicker.saveFile(
        dialogTitle: 'Save $fileName',
        fileName: fileName,
        type: file_picker.FileType.custom,
        allowedExtensions: ['csv'],
        bytes: utf8.encode(content),
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

  Future<void> _saveTransactions() {
    return _saveCsv(
      fileName: transactionsExportFileName,
      buildContent: () async {
        final db = ref.read(databaseProvider);
        final ledgerId = ref.read(selectedLedgerProvider);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Export transactions for the selected ledger, or export all exchange rates.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
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
