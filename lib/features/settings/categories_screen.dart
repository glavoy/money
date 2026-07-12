import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../shared/providers.dart';
import '../../sync/sync_service.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    final expenses = categories
        .where((c) => c.kind == CategoryKind.expense)
        .toList();
    final incomes = categories
        .where((c) => c.kind == CategoryKind.income)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editCategory(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        children: [
          for (final (label, list) in [
            ('Expense', expenses),
            ('Income', incomes),
          ]) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final c in list)
              ListTile(
                title: Text(
                  c.name,
                  style: c.archived
                      ? const TextStyle(decoration: TextDecoration.lineThrough)
                      : null,
                ),
                subtitle: c.archived ? const Text('Archived') : null,
                trailing: IconButton(
                  icon: Icon(
                    c.archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                  ),
                  tooltip: c.archived ? 'Unarchive' : 'Archive',
                  onPressed: () async {
                    final db = ref.read(databaseProvider);
                    await (db.update(
                      db.categories,
                    )..where((t) => t.id.equals(c.id))).write(
                      CategoriesCompanion(
                        archived: Value(!c.archived),
                        updatedAt: Value(DateTime.now().toUtc()),
                      ),
                    );
                    ref.read(syncServiceProvider).syncSilently();
                  },
                ),
                onTap: () => _editCategory(context, ref, c),
              ),
          ],
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Future<void> _editCategory(
    BuildContext context,
    WidgetRef ref,
    Category? existing,
  ) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    var kind = existing?.kind ?? CategoryKind.expense;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New category' : 'Edit category'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              if (existing == null)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: CategoryKind.expense,
                      label: Text('Expense'),
                    ),
                    ButtonSegment(
                      value: CategoryKind.income,
                      label: Text('Income'),
                    ),
                  ],
                  selected: {kind},
                  onSelectionChanged: (s) =>
                      setDialogState(() => kind = s.first),
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
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final db = ref.read(databaseProvider);
                final now = DateTime.now().toUtc();
                if (existing == null) {
                  final count = (await db.getCategories(
                    kind: kind,
                    includeArchived: true,
                  )).length;
                  await db
                      .into(db.categories)
                      .insert(
                        CategoriesCompanion.insert(
                          id: uuid.v4(),
                          name: name,
                          kind: kind,
                          sortOrder: Value(count),
                          createdAt: now,
                          updatedAt: now,
                        ),
                      );
                } else {
                  await (db.update(
                    db.categories,
                  )..where((t) => t.id.equals(existing.id))).write(
                    CategoriesCompanion(
                      name: Value(name),
                      updatedAt: Value(now),
                    ),
                  );
                }
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
