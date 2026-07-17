import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../shared/providers.dart';
import '../../sync/sync_service.dart';

class AccountsManageScreen extends ConsumerWidget {
  const AccountsManageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final ledgerId = ref.watch(selectedLedgerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manage accounts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editAccount(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<Account>>(
        stream: db.watchAccounts(ledgerId: ledgerId, includeArchived: true),
        builder: (context, snapshot) {
          final accounts = snapshot.data ?? [];
          return ListView(
            children: [
              for (final a in accounts)
                _AccountTile(
                  account: a,
                  onEdit: () => _editAccount(context, ref, a),
                ),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editAccount(
    BuildContext context,
    WidgetRef ref,
    Account? existing,
  ) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final openingController = TextEditingController(
      text: existing?.openingBalance.toStringAsFixed(0) ?? '0',
    );
    var type = existing?.type ?? AccountType.cash;
    var currency = existing?.currency ?? 'UGX';
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New account' : 'Edit account'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(
                      value: AccountType.cash,
                      child: Text('Cash'),
                    ),
                    DropdownMenuItem(
                      value: AccountType.bank,
                      child: Text('Bank'),
                    ),
                    DropdownMenuItem(
                      value: AccountType.mobileMoney,
                      child: Text('Mobile money'),
                    ),
                    DropdownMenuItem(
                      value: AccountType.creditCard,
                      child: Text('Credit card'),
                    ),
                  ],
                  onChanged: (v) => setDialogState(() => type = v ?? type),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: currency,
                  decoration: const InputDecoration(labelText: 'Currency'),
                  items: const [
                    DropdownMenuItem(value: 'UGX', child: Text('UGX')),
                    DropdownMenuItem(value: 'USD', child: Text('USD')),
                    DropdownMenuItem(value: 'CAD', child: Text('CAD')),
                  ],
                  onChanged: (v) =>
                      setDialogState(() => currency = v ?? currency),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: openingController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Opening balance',
                    helperText: 'Balance before the first recorded transaction',
                  ),
                ),
              ],
            ),
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
                final opening =
                    double.tryParse(
                      openingController.text.replaceAll(',', ''),
                    ) ??
                    0;
                final db = ref.read(databaseProvider);
                final ledgerId = ref.read(selectedLedgerProvider);
                final now = DateTime.now().toUtc();
                if (existing == null) {
                  final count = (await db.getAccounts(
                    ledgerId: ledgerId,
                    includeArchived: true,
                  )).length;
                  await db
                      .into(db.accounts)
                      .insert(
                        AccountsCompanion.insert(
                          id: uuid.v4(),
                          ledgerId: Value(ledgerId),
                          name: name,
                          type: type,
                          currency: currency,
                          openingBalance: Value(opening),
                          sortOrder: Value(count),
                          createdAt: now,
                          updatedAt: now,
                        ),
                      );
                } else {
                  await (db.update(
                    db.accounts,
                  )..where((t) => t.id.equals(existing.id))).write(
                    AccountsCompanion(
                      name: Value(name),
                      type: Value(type),
                      currency: Value(currency),
                      openingBalance: Value(opening),
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

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.account, required this.onEdit});

  final Account account;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return FutureBuilder<int>(
      future: db.countTransactionsForAccount(account.id),
      builder: (context, snapshot) {
        final transactionCount = snapshot.data;
        final subtitleParts = [
          account.type.replaceAll('_', ' '),
          account.currency,
          if (account.archived) 'archived',
          if (transactionCount != null)
            '$transactionCount ${transactionCount == 1 ? 'transaction' : 'transactions'}',
        ];

        return ListTile(
          title: Text(
            account.name,
            style: account.archived
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
          ),
          subtitle: Text(subtitleParts.join(' · ')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  account.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                tooltip: account.archived ? 'Unarchive' : 'Archive',
                onPressed: () => _setArchived(ref, !account.archived),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete account',
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
    await (db.update(db.accounts)..where((t) => t.id.equals(account.id))).write(
      AccountsCompanion(
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
              title: const Text('Delete account?'),
              content: Text(
                '"${account.name}" is not used by any transactions. Delete it?',
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
      final deleted = await db.softDeleteAccountIfUnused(account.id);
      if (deleted) {
        ref.read(syncServiceProvider).syncSilently();
      }
      return;
    }

    final archive =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Account has history'),
            content: Text(
              '"${account.name}" is used by $transactionCount '
              '${transactionCount == 1 ? 'transaction' : 'transactions'}. '
              'Archive it instead so balances and reports stay intact.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: account.archived
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
