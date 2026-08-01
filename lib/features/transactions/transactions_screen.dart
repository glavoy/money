import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../shared/widgets.dart';
import '../quick_add/transaction_sheet.dart';

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  static const _historyPageMonths = 12;

  String? _accountId;
  String? _categoryId;
  String? _kind;
  _DatePreset _datePreset = _DatePreset.recentMonths;
  DateTimeRange? _customRange;
  int _recentMonths = _historyPageMonths;

  bool get _hasFilters =>
      _accountId != null ||
      _categoryId != null ||
      _kind != null ||
      _datePreset != _DatePreset.recentMonths ||
      _recentMonths != _historyPageMonths;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);
    final ledgerId = ref.watch(selectedLedgerProvider);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final allAccounts = ref.watch(allAccountsProvider).value ?? [];
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    final latestRate = ref.watch(latestRateProvider).value;
    // Resolves each transaction's own account (including archived ones,
    // e.g. imported-history buckets) so its true currency and name are
    // shown correctly. `accounts` (non-archived) is used below only for
    // the account filter picker.
    final accountById = {for (final a in allAccounts) a.id: a};
    final categoryById = {for (final c in categories) c.id: c};
    final range = _effectiveRange();

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add transaction',
        onPressed: () => showTransactionSheet(
          context,
          ref,
          initialAccountId: _accountId,
          initialKind: _kind,
        ),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: SegmentedButton<String?>(
              segments: const [
                ButtonSegment(value: null, label: Text('All')),
                ButtonSegment(value: TxKind.income, label: Text('Income')),
                ButtonSegment(value: TxKind.expense, label: Text('Expense')),
                ButtonSegment(value: TxKind.transfer, label: Text('Transfer')),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
          ),
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
                          label: Text(_dateLabel(range)),
                          selected: _datePreset != _DatePreset.allHistory,
                          onSelected: (_) => _pickDatePreset(context),
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
                            final id =
                                await _pickFromList(context, 'Category', [
                                  for (final c in categories.where(
                                    (c) => !c.archived,
                                  ))
                                    (c.id, c.name),
                                ]);
                            if (id != null) {
                              setState(
                                () => _categoryId = id == '' ? null : id,
                              );
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
                      _kind = null;
                      _datePreset = _DatePreset.recentMonths;
                      _customRange = null;
                      _recentMonths = _historyPageMonths;
                    }),
                  ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Transaction>>(
              stream: db.watchTransactions(
                ledgerId: ledgerId,
                from: range == null
                    ? null
                    : DateTime.utc(
                        range.start.year,
                        range.start.month,
                        range.start.day,
                      ),
                to: range == null
                    ? null
                    : DateTime.utc(
                        range.end.year,
                        range.end.month,
                        range.end.day,
                      ),
                accountId: _accountId,
                categoryId: _categoryId,
                kind: _kind,
                limit: null,
              ),
              builder: (context, snapshot) {
                final txs = snapshot.data ?? [];
                if (txs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
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
                          if (_canLoadOlder) ...[
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: _loadOlder,
                              icon: const Icon(Icons.history),
                              label: const Text('Load older'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }
                // Group by day.
                final groups = <DateTime, List<Transaction>>{};
                for (final t in txs) {
                  final day = DateTime.utc(
                    t.date.year,
                    t.date.month,
                    t.date.day,
                  );
                  groups.putIfAbsent(day, () => []).add(t);
                }
                final days = groups.keys.toList()
                  ..sort((a, b) => b.compareTo(a));
                return ListView.builder(
                  // Clears the add-transaction FAB.
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: days.length + (_canLoadOlder ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == days.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        child: OutlinedButton.icon(
                          onPressed: _loadOlder,
                          icon: const Icon(Icons.history),
                          label: const Text('Load older'),
                        ),
                      );
                    }
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
      ),
    );
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('EEEE d MMMM yyyy').format(day);
  }

  bool get _canLoadOlder => _datePreset == _DatePreset.recentMonths;

  void _loadOlder() {
    setState(() => _recentMonths += _historyPageMonths);
  }

  DateTimeRange? _effectiveRange() {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    return switch (_datePreset) {
      _DatePreset.recentMonths => DateTimeRange(
        start: _addMonths(tomorrow, -_recentMonths),
        end: tomorrow,
      ),
      _DatePreset.last30Days => DateTimeRange(
        start: tomorrow.subtract(const Duration(days: 30)),
        end: tomorrow,
      ),
      _DatePreset.last3Months => DateTimeRange(
        start: _addMonths(tomorrow, -3),
        end: tomorrow,
      ),
      _DatePreset.thisYear => DateTimeRange(
        start: DateTime.utc(today.year),
        end: tomorrow,
      ),
      _DatePreset.lastYear => DateTimeRange(
        start: DateTime.utc(today.year - 1),
        end: DateTime.utc(today.year),
      ),
      _DatePreset.custom => _customRange,
      _DatePreset.allHistory => null,
    };
  }

  String _dateLabel(DateTimeRange? range) {
    return switch (_datePreset) {
      _DatePreset.recentMonths =>
        _recentMonths == _historyPageMonths
            ? 'Last 12 months'
            : 'Last $_recentMonths months',
      _DatePreset.last30Days => 'Last 30 days',
      _DatePreset.last3Months => 'Last 3 months',
      _DatePreset.thisYear => 'This year',
      _DatePreset.lastYear => 'Last year',
      _DatePreset.allHistory => 'All history',
      _DatePreset.custom =>
        range == null
            ? 'Custom range'
            : '${DateFormat('d MMM yy').format(range.start)} – ${DateFormat('d MMM yy').format(range.end)}',
    };
  }

  Future<void> _pickDatePreset(BuildContext context) async {
    final picked = await showModalBottomSheet<_DatePreset>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                'Date range',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final preset in _DatePreset.values)
              ListTile(
                selected: preset == _datePreset,
                title: Text(_presetLabel(preset)),
                trailing: preset == _datePreset
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, preset),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (!context.mounted) return;

    if (picked == _DatePreset.custom) {
      final initialRange = _customRange ?? _effectiveRange();
      final custom = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime.now().add(const Duration(days: 1)),
        initialDateRange: initialRange,
      );
      if (custom == null) return;
      setState(() {
        _datePreset = picked;
        _customRange = custom;
      });
      return;
    }

    setState(() {
      _datePreset = picked;
      _recentMonths = _historyPageMonths;
    });
  }
}

enum _DatePreset {
  recentMonths,
  last30Days,
  last3Months,
  thisYear,
  lastYear,
  allHistory,
  custom,
}

String _presetLabel(_DatePreset preset) {
  return switch (preset) {
    _DatePreset.recentMonths => 'Last 12 months',
    _DatePreset.last30Days => 'Last 30 days',
    _DatePreset.last3Months => 'Last 3 months',
    _DatePreset.thisYear => 'This year',
    _DatePreset.lastYear => 'Last year',
    _DatePreset.allHistory => 'All history',
    _DatePreset.custom => 'Custom range',
  };
}

DateTime _addMonths(DateTime date, int months) {
  return DateTime.utc(date.year, date.month + months, date.day);
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
        return confirmDeleteTransaction(
          context,
          title,
          formatMoney(tx.amount, currency),
        );
      },
      onDismissed: (_) => deleteTransactionWithSync(ref, tx.id),
      child: ListTile(
        leading: KindAvatar(kind: tx.kind),
        title: Row(
          children: [
            Flexible(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            if (tx.excludeFromReport) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: 'Excluded from reports',
                child: Icon(
                  Icons.visibility_off_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        subtitle: subtitleParts.isEmpty
            ? null
            : Text(subtitleParts.join(' · ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
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
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete entry',
              onPressed: () async {
                final confirmed = await confirmDeleteTransaction(
                  context,
                  title,
                  formatMoney(tx.amount, currency),
                );
                if (confirmed) {
                  await deleteTransactionWithSync(ref, tx.id);
                }
              },
            ),
          ],
        ),
        onTap: () => showTransactionSheet(context, ref, tx: tx),
      ),
    );
  }
}
