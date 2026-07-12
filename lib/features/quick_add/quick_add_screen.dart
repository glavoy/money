import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../features/transactions/transactions_screen.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../sync/sync_service.dart';

class QuickAddScreen extends ConsumerStatefulWidget {
  const QuickAddScreen({super.key});

  @override
  ConsumerState<QuickAddScreen> createState() => _QuickAddScreenState();
}

class _QuickAddScreenState extends ConsumerState<QuickAddScreen> {
  String _kind = TxKind.expense;
  DateTime _date = DateTime.now();
  final _amountController = TextEditingController();
  final _toAmountController = TextEditingController();
  final _noteController = TextEditingController();
  String? _categoryId;
  String? _accountId;
  String? _toAccountId;

  @override
  void dispose() {
    _amountController.dispose();
    _toAmountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  DateTime get _dateOnly => DateTime.utc(_date.year, _date.month, _date.day);

  DateTime get _todayOnly {
    final now = DateTime.now();
    return DateTime.utc(now.year, now.month, now.day);
  }

  bool get _isToday => _dateOnly == _todayOnly;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: _todayOnly,
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _shiftDate(int days) {
    final next = DateTime.utc(_date.year, _date.month, _date.day + days);
    final min = DateTime.utc(2000);
    final max = _todayOnly;
    if (next.isBefore(min) || next.isAfter(max)) return;
    setState(() => _date = next);
  }

  void _goToToday() {
    setState(() => _date = _todayOnly);
  }

  Future<void> _save(List<Account> accounts) async {
    final db = ref.read(databaseProvider);
    final amount = double.tryParse(_amountController.text.replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      _toast('Enter an amount');
      return;
    }
    if (_accountId == null) {
      _toast('Pick an account');
      return;
    }
    final isTransfer = _kind == TxKind.transfer;
    if (!isTransfer && _categoryId == null) {
      _toast('Pick a category');
      return;
    }

    double? toAmount;
    if (isTransfer) {
      if (_toAccountId == null || _toAccountId == _accountId) {
        _toast('Pick a destination account');
        return;
      }
      final from = accounts.firstWhere((a) => a.id == _accountId);
      final to = accounts.firstWhere((a) => a.id == _toAccountId);
      if (from.currency == to.currency) {
        toAmount =
            double.tryParse(_toAmountController.text.replaceAll(',', '')) ??
            amount;
      } else {
        toAmount = double.tryParse(
          _toAmountController.text.replaceAll(',', ''),
        );
        if (toAmount == null || toAmount <= 0) {
          _toast('Enter the amount received (${to.currency})');
          return;
        }
      }
    }

    final now = DateTime.now().toUtc();
    await db.upsertTransaction(
      TransactionsCompanion.insert(
        id: uuid.v4(),
        date: _dateOnly,
        kind: _kind,
        amount: amount,
        accountId: _accountId!,
        categoryId: Value(isTransfer ? null : _categoryId),
        toAccountId: Value(isTransfer ? _toAccountId : null),
        toAmount: Value(toAmount),
        note: Value(
          _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );
    ref.read(syncServiceProvider).syncSilently();
    ref.read(lastAccountProvider.notifier).set(_accountId!);
    setState(() {
      _amountController.clear();
      _toAmountController.clear();
      _noteController.clear();
      // Keep category/account selected: entering several similar rows is common.
    });
    _toast('Saved');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories =
        ref
            .watch(
              _kind == TxKind.income
                  ? incomeCategoriesProvider
                  : expenseCategoriesProvider,
            )
            .value ??
        [];
    _accountId ??=
        ref.watch(lastAccountProvider) ??
        (accounts.isNotEmpty ? accounts.first.id : null);

    final isTransfer = _kind == TxKind.transfer;
    final selectedAccount =
        accounts.where((a) => a.id == _accountId).firstOrNull ??
        accounts.firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: TxKind.expense, label: Text('Expense')),
                  ButtonSegment(value: TxKind.income, label: Text('Income')),
                  ButtonSegment(
                    value: TxKind.transfer,
                    label: Text('Transfer'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _categoryId = null;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final amountField = TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: Theme.of(context).textTheme.headlineMedium,
              decoration: InputDecoration(
                labelText: isTransfer
                    ? 'Amount sent (${selectedAccount?.currency ?? ''})'
                    : 'Amount (${selectedAccount?.currency ?? ''})',
                border: const OutlineInputBorder(),
              ),
            );
            final dateControls = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Previous day',
                  onPressed: () => _shiftDate(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(DateFormat('EEE d MMM').format(_date)),
                ),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: 'Next day',
                  onPressed: _isToday ? null : () => _shiftDate(1),
                  icon: const Icon(Icons.chevron_right),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 64,
                  child: TextButton(
                    onPressed: _isToday ? null : _goToToday,
                    style: TextButton.styleFrom(
                      disabledForegroundColor: Colors.transparent,
                    ),
                    child: const Text('Today'),
                  ),
                ),
              ],
            );
            if (constraints.maxWidth < 430) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  amountField,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: dateControls),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: amountField),
                const SizedBox(width: 8),
                dateControls,
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          isTransfer ? 'From account' : 'Account',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: -4,
          children: [
            for (final a in accounts)
              ChoiceChip(
                label: Text(a.name),
                selected: _accountId == a.id,
                onSelected: (_) => setState(() => _accountId = a.id),
              ),
          ],
        ),
        if (isTransfer) ...[
          const SizedBox(height: 12),
          Text('To account', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: -4,
            children: [
              for (final a in accounts.where((a) => a.id != _accountId))
                ChoiceChip(
                  label: Text(a.name),
                  selected: _toAccountId == a.id,
                  onSelected: (_) => setState(() => _toAccountId = a.id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _ToAmountField(
            accounts: accounts,
            fromId: _accountId,
            toId: _toAccountId,
            controller: _toAmountController,
          ),
        ] else ...[
          const SizedBox(height: 12),
          Text('Category', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: -4,
            children: [
              for (final c in categories)
                ChoiceChip(
                  label: Text(c.name),
                  selected: _categoryId == c.id,
                  onSelected: (_) => setState(() => _categoryId = c.id),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _noteController,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: accounts.isEmpty ? null : () => _save(accounts),
          icon: const Icon(Icons.check),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Save'),
          ),
        ),
        const SizedBox(height: 24),
        _DaySummary(date: _dateOnly),
      ],
    );
  }
}

/// Destination amount for transfers; auto-mirrors the sent amount when both
/// accounts share a currency, otherwise asks for the received amount.
class _ToAmountField extends StatelessWidget {
  const _ToAmountField({
    required this.accounts,
    required this.fromId,
    required this.toId,
    required this.controller,
  });

  final List<Account> accounts;
  final String? fromId;
  final String? toId;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final from = accounts.where((a) => a.id == fromId).firstOrNull;
    final to = accounts.where((a) => a.id == toId).firstOrNull;
    if (from == null || to == null) return const SizedBox.shrink();
    final sameCurrency = from.currency == to.currency;
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: sameCurrency
            ? 'Amount received (${to.currency}) — leave empty to match'
            : 'Amount received (${to.currency})',
        helperText: sameCurrency
            ? null
            : 'Currency exchange: enter what actually arrived',
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// Entries and total for the selected day, shown under the entry form.
class _DaySummary extends ConsumerWidget {
  const _DaySummary({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    return StreamBuilder<List<Transaction>>(
      stream: db.watchTransactions(from: date, to: date, limit: 200),
      builder: (context, snapshot) {
        final txs = snapshot.data ?? [];
        final accountById = {for (final a in accounts) a.id: a};
        final categoryById = {for (final c in categories) c.id: c};
        double totalUgx = 0;
        final latestRate = ref.watch(latestRateProvider).value;
        for (final t in txs.where((t) => t.kind == TxKind.expense)) {
          final currency = CurrencyX.fromCode(
            accountById[t.accountId]?.currency ?? 'UGX',
          );
          totalUgx +=
              convertWithRate(t.amount, currency, Currency.ugx, latestRate) ??
              t.amount;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  DateFormat('EEEE d MMMM').format(date),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'Spent: ${formatMoney(totalUgx, Currency.ugx)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (txs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No entries yet for this day.'),
              ),
            for (final t in txs)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(switch (t.kind) {
                  TxKind.income => Icons.arrow_downward,
                  TxKind.transfer => Icons.swap_horiz,
                  _ => Icons.arrow_upward,
                }),
                title: Text(
                  t.kind == TxKind.transfer
                      ? '${accountById[t.accountId]?.name ?? '?'} → ${accountById[t.toAccountId]?.name ?? '?'}'
                      : (categoryById[t.categoryId]?.name ?? 'Uncategorised'),
                ),
                subtitle: t.note == null ? null : Text(t.note!),
                onTap: () => showEditTransactionSheet(context, ref, t),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatMoney(
                        t.amount,
                        CurrencyX.fromCode(
                          accountById[t.accountId]?.currency ?? 'UGX',
                        ),
                      ),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    IconButton(
                      tooltip: 'Edit entry',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () =>
                          showEditTransactionSheet(context, ref, t),
                    ),
                    IconButton(
                      tooltip: 'Delete entry',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final currency = CurrencyX.fromCode(
                          accountById[t.accountId]?.currency ?? 'UGX',
                        );
                        final title = t.kind == TxKind.transfer
                            ? '${accountById[t.accountId]?.name ?? '?'} -> ${accountById[t.toAccountId]?.name ?? '?'}'
                            : (categoryById[t.categoryId]?.name ??
                                  'Uncategorised');
                        final delete = await confirmDeleteTransaction(
                          context,
                          t,
                          title: title,
                          currency: currency,
                        );
                        if (!delete) return;
                        await db.softDeleteTransaction(t.id);
                        ref.read(syncServiceProvider).syncSilently();
                      },
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
