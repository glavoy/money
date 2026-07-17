import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/providers.dart';
import '../../sync/fx_fetcher.dart';
import '../../sync/sync_service.dart';

class FxRatesScreen extends ConsumerStatefulWidget {
  const FxRatesScreen({super.key});

  @override
  ConsumerState<FxRatesScreen> createState() => _FxRatesScreenState();
}

class _FxRatesScreenState extends ConsumerState<FxRatesScreen> {
  bool _fetching = false;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exchange rates'),
        actions: [
          IconButton(
            tooltip: 'Fetch today\'s rates',
            icon: _fetching
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined),
            onPressed: _fetching
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _fetching = true);
                    final error = await fetchTodaysRates(db);
                    if (error == null) {
                      ref.read(syncServiceProvider).syncSilently();
                    }
                    if (!mounted) return;
                    setState(() => _fetching = false);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(error ?? 'Rates updated for today'),
                      ),
                    );
                  },
          ),
          IconButton(
            tooltip: 'Fetch rates for a date',
            icon: const Icon(Icons.event_available_outlined),
            onPressed: _fetching ? null : () => _fetchForDate(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Enter a rate manually',
        onPressed: () => _editRate(context, null),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<FxRate>>(
        stream:
            (db.select(db.fxRates)
                  ..where((r) => r.deleted.equals(false))
                  ..orderBy([(r) => OrderingTerm.desc(r.date)])
                  ..limit(90))
                .watch(),
        builder: (context, snapshot) {
          final rates = snapshot.data ?? [];
          if (rates.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No rates yet.\nFetch rates with the cloud or calendar button, enter one manually, or import x-rates.csv.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rates.length,
            itemBuilder: (context, i) {
              final r = rates[i];
              return ListTile(
                title: Text(DateFormat('EEE d MMM yyyy').format(r.date)),
                subtitle: Text(
                  [
                    if (r.usdUgx != null) 'USD ${r.usdUgx!.toStringAsFixed(0)}',
                    if (r.cadUgx != null) 'CAD ${r.cadUgx!.toStringAsFixed(0)}',
                    if (r.usdCad != null)
                      'USD/CAD ${r.usdCad!.toStringAsFixed(4)}',
                  ].join(' · '),
                ),
                trailing: Text(r.source),
                onTap: () => _editRate(context, r),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _fetchForDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _fetching = true);
    final error = await fetchRatesForDate(ref.read(databaseProvider), picked);
    if (error == null) {
      ref.read(syncServiceProvider).syncSilently();
    }
    if (!mounted) return;
    setState(() => _fetching = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error ??
              'Rates updated for ${DateFormat('d MMM yyyy').format(picked)}',
        ),
      ),
    );
  }

  Future<void> _editRate(BuildContext context, FxRate? existing) async {
    final db = ref.read(databaseProvider);
    var date = existing?.date ?? DateTime.now();
    final usdUgxController = TextEditingController(
      text: existing?.usdUgx?.toStringAsFixed(0) ?? '',
    );
    final cadUgxController = TextEditingController(
      text: existing?.cadUgx?.toStringAsFixed(0) ?? '',
    );
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Exchange rate'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(DateFormat('d MMM yyyy').format(date)),
                onPressed: existing != null
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) setDialogState(() => date = picked);
                      },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: usdUgxController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '1 USD in UGX'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cadUgxController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '1 CAD in UGX'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final usdUgx = double.tryParse(
                  usdUgxController.text.replaceAll(',', ''),
                );
                final cadUgx = double.tryParse(
                  cadUgxController.text.replaceAll(',', ''),
                );
                if (usdUgx == null && cadUgx == null) return;
                final usdCad = (usdUgx != null && cadUgx != null && cadUgx != 0)
                    ? usdUgx / cadUgx
                    : null;
                await db.upsertRate(
                  date: date,
                  usdUgx: usdUgx,
                  cadUgx: cadUgx,
                  usdCad: usdCad,
                  source: FxSource.manual,
                  newId: uuid.v4,
                );
                ref.read(syncServiceProvider).syncSilently();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
