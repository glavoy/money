import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers.dart';
import '../../sync/sync_service.dart';
import 'csv_import.dart';

class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  bool _busy = false;
  final List<String> _log = [];

  void _append(String line) => setState(() => _log.add(line));

  Future<void> _pickAndImport() async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final db = ref.read(databaseProvider);
    final ledgerId = ref.read(selectedLedgerProvider);
    try {
      final picked = await file_picker.FilePicker.pickFiles(
        dialogTitle: 'Choose CSV files',
        allowMultiple: true,
        type: file_picker.FileType.custom,
        allowedExtensions: ['csv'],
        lockParentWindow: true,
      );
      if (picked == null || picked.files.isEmpty) {
        _append('Import cancelled.');
        return;
      }

      for (final file in picked.files) {
        final path = file.path;
        if (path == null) continue;
        _append('Importing ${file.name}…');
        final content = await File(path).readAsString(encoding: utf8);
        final result = await importCsvContent(
          db,
          content,
          ledgerId: ledgerId,
          onProgress: (done) => _append('  …$done rows'),
        );
        _append(
          result.kind == 'unknown'
              ? '  ${file.name}: unrecognised columns, skipped.'
              : '  ${result.kind}: ${result.imported} imported, ${result.skipped} skipped.',
        );
      }
      _append('Done.');
      ref.read(syncServiceProvider).syncSilently();
    } catch (e) {
      _append('Import failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickAndImportHistoricalUsdIncome() async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    try {
      final picked = await file_picker.FilePicker.pickFiles(
        dialogTitle: 'Choose income_usd.csv',
        allowMultiple: false,
        type: file_picker.FileType.custom,
        allowedExtensions: ['csv'],
        lockParentWindow: true,
      );
      if (picked == null || picked.files.isEmpty) {
        _append('Import cancelled.');
        return;
      }
      final file = picked.files.single;
      final path = file.path;
      if (path == null) {
        _append('No readable file path returned.');
        return;
      }
      _append('Importing ${file.name}…');
      final result = await importHistoricalUsdIncomeCsv(
        ref.read(databaseProvider),
        await File(path).readAsString(encoding: utf8),
        ledgerId: ref.read(selectedLedgerProvider),
        onProgress: (done) => _append('  …$done rows'),
      );
      if (result.kind == 'income_usd_missing_account') {
        _append('  Missing archived USD account named Imported history USD.');
      } else {
        _append(
          '  historical USD income: ${result.imported} imported, ${result.skipped} skipped.',
        );
        ref.read(syncServiceProvider).syncSilently();
      }
      _append('Done.');
    } catch (e) {
      _append('Import failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import data')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Import transactions.csv or x-rates.csv. Re-importing the same '
              'files is safe: transactions overwrite by id, and exchange '
              'rates overwrite the matching date.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _pickAndImport,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(_busy ? 'Importing…' : 'Choose CSV files'),
            ),
            const SizedBox(height: 24),
            const Text(
              'Historical USD income imports income_usd.csv into '
              'Imported history USD. Delete the old UGX income rows separately.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickAndImportHistoricalUsdIncome,
              icon: const Icon(Icons.attach_money),
              label: const Text('Import income_usd.csv'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  for (final line in _log)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
