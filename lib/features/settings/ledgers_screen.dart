import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../shared/providers.dart';
import '../../sync/sync_service.dart';

class LedgersScreen extends ConsumerWidget {
  const LedgersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final selectedId = ref.watch(selectedLedgerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Ledgers')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editLedger(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<Ledger>>(
        stream: db.watchLedgers(includeArchived: true),
        builder: (context, snapshot) {
          final ledgers = snapshot.data ?? [];
          return ListView(
            children: [
              for (final ledger in ledgers)
                ListTile(
                  leading: Icon(
                    selectedId == ledger.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(
                    ledger.name,
                    style: ledger.archived
                        ? const TextStyle(
                            decoration: TextDecoration.lineThrough,
                          )
                        : null,
                  ),
                  subtitle: ledger.archived ? const Text('Archived') : null,
                  trailing: IconButton(
                    icon: Icon(
                      ledger.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                    ),
                    tooltip: ledger.archived ? 'Unarchive' : 'Archive',
                    onPressed: selectedId == ledger.id && !ledger.archived
                        ? null
                        : () => _setArchived(ref, ledger, !ledger.archived),
                  ),
                  onTap: ledger.archived
                      ? () => _editLedger(context, ref, ledger)
                      : () {
                          ref
                              .read(selectedLedgerProvider.notifier)
                              .set(ledger.id);
                          Navigator.pop(context);
                        },
                  onLongPress: () => _editLedger(context, ref, ledger),
                ),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editLedger(
    BuildContext context,
    WidgetRef ref,
    Ledger? existing,
  ) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'New ledger' : 'Edit ledger'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              final db = ref.read(databaseProvider);
              final now = DateTime.now().toUtc();
              if (existing == null) {
                final count = (await db.getLedgers(
                  includeArchived: true,
                )).length;
                final id = uuid.v4();
                await db
                    .into(db.ledgers)
                    .insert(
                      LedgersCompanion.insert(
                        id: id,
                        name: name,
                        sortOrder: Value(count),
                        createdAt: now,
                        updatedAt: now,
                      ),
                    );
                ref.read(selectedLedgerProvider.notifier).set(id);
              } else {
                await (db.update(
                  db.ledgers,
                )..where((l) => l.id.equals(existing.id))).write(
                  LedgersCompanion(name: Value(name), updatedAt: Value(now)),
                );
              }
              ref.read(syncServiceProvider).syncSilently();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _setArchived(WidgetRef ref, Ledger ledger, bool archived) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.ledgers)..where((l) => l.id.equals(ledger.id))).write(
      LedgersCompanion(
        archived: Value(archived),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    ref.read(syncServiceProvider).syncSilently();
  }
}
