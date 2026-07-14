import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../shared/widgets.dart';

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  String? _accountId;
  String? _categoryId;
  DateTimeRange? _range;

  bool get _hasFilters =>
      _accountId != null || _categoryId != null || _range != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    final latestRate = ref.watch(latestRateProvider).value;
    final accountById = {for (final a in accounts) a.id: a};
    final categoryById = {for (final c in categories) c.id: c};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: Text(
                          _range == null
                              ? 'All dates'
                              : '${DateFormat('d MMM yy').format(_range!.start)} – ${DateFormat('d MMM yy').format(_range!.end)}',
                        ),
                        selected: _range != null,
                        onSelected: (_) async {
                          final picked = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now().add(
                              const Duration(days: 1),
                            ),
                            initialDateRange: _range,
                          );
                          setState(() => _range = picked);
                        },
                      ),
                      const SizedBox(width: 6),
                      FilterChip(
                        label: Text(
                          _accountId == null
                              ? 'All accounts'
                              : accountById[_accountId]?.name ?? '?',
                        ),
                        selected: _accountId != null,
                        onSelected: (_) async {
                          final id = await _pickFromList(context, 'Account', [
                            for (final a in accounts) (a.id, a.name),
                          ]);
                          if (id != null) {
                            setState(() => _accountId = id == '' ? null : id);
                          }
                        },
                      ),
                      const SizedBox(width: 6),
                      FilterChip(
                        label: Text(
                          _categoryId == null
                              ? 'All categories'
                              : categoryById[_categoryId]?.name ?? '?',
                        ),
                        selected: _categoryId != null,
                        onSelected: (_) async {
                          final id = await _pickFromList(context, 'Category', [
                            for (final c in categories.where(
                              (c) => !c.archived,
                            ))
                              (c.id, c.name),
                          ]);
                          if (id != null) {
                            setState(() => _categoryId = id == '' ? null : id);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              if (_hasFilters)
                IconButton(
                  tooltip: 'Clear filters',
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  onPressed: () => setState(() {
                    _accountId = null;
                    _categoryId = null;
                    _range = null;
                  }),
                ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Transaction>>(
            stream: db.watchTransactions(
              from: _range == null
                  ? null
                  : DateTime.utc(
                      _range!.start.year,
                      _range!.start.month,
                      _range!.start.day,
                    ),
              to: _range == null
                  ? null
                  : DateTime.utc(
                      _range!.end.year,
                      _range!.end.month,
                      _range!.end.day,
                    ),
              accountId: _accountId,
              categoryId: _categoryId,
              limit: null,
            ),
            builder: (context, snapshot) {
              final txs = snapshot.data ?? [];
              if (txs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 48,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No transactions',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              }
              // Group by day.
              final groups = <DateTime, List<Transaction>>{};
              for (final t in txs) {
                final day = DateTime.utc(t.date.year, t.date.month, t.date.day);
                groups.putIfAbsent(day, () => []).add(t);
              }
              final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: days.length,
                itemBuilder: (context, i) {
                  final day = days[i];
                  final dayTxs = groups[day]!;
                  double spentUgx = 0;
                  for (final t in dayTxs.where(
                    (t) => t.kind == TxKind.expense,
                  )) {
                    final c = CurrencyX.fromCode(
                      accountById[t.accountId]?.currency ?? 'UGX',
                    );
                    spentUgx +=
                        convertWithRate(
                          t.amount,
                          c,
                          Currency.ugx,
                          latestRate,
                        ) ??
                        t.amount;
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _dayLabel(day),
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            if (spentUgx > 0)
                              Text(
                                formatMoney(spentUgx, Currency.ugx),
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      for (final t in dayTxs)
                        _TransactionTile(
                          tx: t,
                          account: accountById[t.accountId],
                          toAccount: t.toAccountId == null
                              ? null
                              : accountById[t.toAccountId],
                          category: t.categoryId == null
                              ? null
                              : categoryById[t.categoryId],
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('EEEE d MMMM yyyy').format(day);
  }
}

Future<String?> _pickFromList(
  BuildContext context,
  String title,
  List<(String, String)> items,
) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            title: const Text('All'),
            onTap: () => Navigator.pop(context, ''),
          ),
          for (final (id, name) in items)
            ListTile(
              title: Text(name),
              onTap: () => Navigator.pop(context, id),
            ),
        ],
      ),
    ),
  );
}

class _TransactionTile extends ConsumerWidget {
  const _TransactionTile({
    required this.tx,
    required this.account,
    required this.toAccount,
    required this.category,
  });

  final Transaction tx;
  final Account? account;
  final Account? toAccount;
  final Category? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final currency = CurrencyX.fromCode(account?.currency ?? 'UGX');
    final isTransfer = tx.kind == TxKind.transfer;
    final title = isTransfer
        ? '${account?.name ?? '?'} → ${toAccount?.name ?? '?'}'
        : (category?.name ?? 'Uncategorised');
    final subtitleParts = [
      if (!isTransfer) account?.name,
      tx.note,
    ].whereType<String>();
    return Dismissible(
      key: ValueKey(tx.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete, color: theme.colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete entry?'),
                content: Text('$title — ${formatMoney(tx.amount, currency)}'),
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
      },
      onDismissed: (_) =>
          ref.read(databaseProvider).softDeleteTransaction(tx.id),
      child: ListTile(
        leading: KindAvatar(kind: tx.kind),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: subtitleParts.isEmpty
            ? null
            : Text(subtitleParts.join(' · ')),
        trailing: Text(
          '${tx.kind == TxKind.expense
              ? '−'
              : tx.kind == TxKind.income
              ? '+'
              : ''}${formatMoney(tx.amount, currency)}',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: switch (tx.kind) {
              TxKind.income => theme.colorScheme.tertiary,
              TxKind.expense => theme.colorScheme.error,
              _ => theme.colorScheme.onSurfaceVariant,
            },
            fontWeight: FontWeight.w600,
          ),
        ),
        onTap: () => showEditTransactionSheet(context, ref, tx),
      ),
    );
  }
}

/// Bottom sheet to edit an existing transaction's fields.
Future<void> showEditTransactionSheet(
  BuildContext context,
  WidgetRef ref,
  Transaction tx,
) async {
  final db = ref.read(databaseProvider);
  final accounts = await db.getAccounts(includeArchived: true);
  final categories = await db.getCategories(
    kind: tx.kind == TxKind.income ? CategoryKind.income : CategoryKind.expense,
  );
  if (!context.mounted) return;

  final amountController = TextEditingController(
    text: tx.amount.toStringAsFixed(0),
  );
  final toAmountController = TextEditingController(
    text: tx.toAmount?.toStringAsFixed(0) ?? '',
  );
  final noteController = TextEditingController(text: tx.note ?? '');
  var date = tx.date;
  var categoryId = tx.categoryId;
  var accountId = tx.accountId;
  var toAccountId = tx.toAccountId;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              'Edit ${tx.kind}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (picked != null) {
                      setSheetState(
                        () => date = DateTime.utc(
                          picked.year,
                          picked.month,
                          picked.day,
                        ),
                      );
                    }
                  },
                  child: Text(DateFormat('d MMM yyyy').format(date)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: accountId,
              decoration: InputDecoration(
                labelText: tx.kind == TxKind.transfer
                    ? 'From account'
                    : 'Account',
              ),
              items: [
                for (final a in accounts)
                  DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: (v) => setSheetState(() => accountId = v ?? accountId),
            ),
            if (tx.kind == TxKind.transfer) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: toAccountId,
                decoration: const InputDecoration(labelText: 'To account'),
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setSheetState(() => toAccountId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: toAmountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Amount received'),
              ),
            ] else ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: categories.any((c) => c.id == categoryId)
                    ? categoryId
                    : null,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setSheetState(() => categoryId = v),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(labelText: 'Note'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                final amount = double.tryParse(
                  amountController.text.replaceAll(',', ''),
                );
                if (amount == null || amount <= 0) return;
                await db.upsertTransaction(
                  TransactionsCompanion.insert(
                    id: tx.id,
                    date: date,
                    kind: tx.kind,
                    amount: amount,
                    accountId: accountId,
                    categoryId: Value(
                      tx.kind == TxKind.transfer ? null : categoryId,
                    ),
                    toAccountId: Value(
                      tx.kind == TxKind.transfer ? toAccountId : null,
                    ),
                    toAmount: Value(
                      tx.kind == TxKind.transfer
                          ? double.tryParse(
                                  toAmountController.text.replaceAll(',', ''),
                                ) ??
                                amount
                          : null,
                    ),
                    note: Value(
                      noteController.text.trim().isEmpty
                          ? null
                          : noteController.text.trim(),
                    ),
                    createdAt: tx.createdAt,
                    updatedAt: DateTime.now().toUtc(),
                  ),
                );
                if (context.mounted) Navigator.pop(context);
              },
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
    ),
  );
}
