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
              _CategoryTile(
                category: c,
                onEdit: () => _editCategory(context, ref, c),
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
                final ledgerId = ref.read(selectedLedgerProvider);
                final now = DateTime.now().toUtc();
                if (existing == null) {
                  final count = (await db.getCategories(
                    ledgerId: ledgerId,
                    kind: kind,
                    includeArchived: true,
                  )).length;
                  await db
                      .into(db.categories)
                      .insert(
                        CategoriesCompanion.insert(
                          id: uuid.v4(),
                          ledgerId: Value(ledgerId),
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

class _CategoryTile extends ConsumerWidget {
  const _CategoryTile({required this.category, required this.onEdit});

  final Category category;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return FutureBuilder<int>(
      future: db.countTransactionsForCategory(category.id),
      builder: (context, snapshot) {
        final transactionCount = snapshot.data;
        final subtitleParts = [
          if (category.archived) 'Archived',
          if (transactionCount != null)
            '$transactionCount ${transactionCount == 1 ? 'transaction' : 'transactions'}',
        ];

        return ListTile(
          title: Text(
            category.name,
            style: category.archived
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
          ),
          subtitle: subtitleParts.isEmpty
              ? null
              : Text(subtitleParts.join(' | ')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  category.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                tooltip: category.archived ? 'Unarchive' : 'Archive',
                onPressed: () => _setArchived(ref, !category.archived),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete category',
                onPressed: transactionCount == null
                    ? null
                    : () =>
                          _deleteOrOfferArchive(context, ref, transactionCount),
              ),
            ],
          ),
          onTap: onEdit,
        );
      },
    );
  }

  Future<void> _setArchived(WidgetRef ref, bool archived) async {
    final db = ref.read(databaseProvider);
    await (db.update(
      db.categories,
    )..where((t) => t.id.equals(category.id))).write(
      CategoriesCompanion(
        archived: Value(archived),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    ref.read(syncServiceProvider).syncSilently();
  }

  Future<void> _deleteOrOfferArchive(
    BuildContext context,
    WidgetRef ref,
    int transactionCount,
  ) async {
    final db = ref.read(databaseProvider);
    if (transactionCount == 0) {
      final delete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete category?'),
              content: Text(
                '"${category.name}" is not used by any transactions. Delete it?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ) ??
          false;
      if (!delete) return;
      final deleted = await db.softDeleteCategoryIfUnused(category.id);
      if (deleted) {
        ref.read(syncServiceProvider).syncSilently();
      }
      return;
    }

    final archive =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Category is in use'),
            content: Text(
              '"${category.name}" is used by $transactionCount '
              '${transactionCount == 1 ? 'transaction' : 'transactions'}. '
              'Archive it instead so history and reports stay intact.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: category.archived
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Archive'),
              ),
            ],
          ),
        ) ??
        false;
    if (archive) {
      await _setArchived(ref, true);
    }
  }
}
