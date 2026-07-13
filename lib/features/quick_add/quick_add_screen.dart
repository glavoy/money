import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../shared/widgets.dart';

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

  bool get _isToday {
    final now = DateTime.now();
    return _date.year == now.year && _date.month == now.month && _date.day == now.day;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
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
        toAmount = double.tryParse(_toAmountController.text.replaceAll(',', '')) ?? amount;
      } else {
        toAmount = double.tryParse(_toAmountController.text.replaceAll(',', ''));
        if (toAmount == null || toAmount <= 0) {
          _toast('Enter the amount received (${to.currency})');
          return;
        }
      }
    }

    final now = DateTime.now().toUtc();
    await db.upsertTransaction(TransactionsCompanion.insert(
      id: uuid.v4(),
      date: _dateOnly,
      kind: _kind,
      amount: amount,
      accountId: _accountId!,
      categoryId: Value(isTransfer ? null : _categoryId),
      toAccountId: Value(isTransfer ? _toAccountId : null),
      toAmount: Value(toAmount),
      note: Value(_noteController.text.trim().isEmpty ? null : _noteController.text.trim()),
      createdAt: now,
      updatedAt: now,
    ));
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
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories = ref
            .watch(_kind == TxKind.income ? incomeCategoriesProvider : expenseCategoriesProvider)
            .value ??
        [];
    _accountId ??= ref.watch(lastAccountProvider) ?? (accounts.isNotEmpty ? accounts.first.id : null);

    final isTransfer = _kind == TxKind.transfer;
    final selectedAccount =
        accounts.where((a) => a.id == _accountId).firstOrNull ?? accounts.firstOrNull;
    final currency = CurrencyX.fromCode(selectedAccount?.currency ?? 'UGX');

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: TxKind.expense, label: Text('Expense')),
                  ButtonSegment(value: TxKind.income, label: Text('Income')),
                  ButtonSegment(value: TxKind.transfer, label: Text('Transfer')),
                ],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _categoryId = null;
                }),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        labelText: isTransfer ? 'Amount sent' : 'Amount',
                        suffixText: selectedAccount?.currency,
                        suffixStyle: theme.textTheme.titleMedium
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: Icon(Icons.calendar_today,
                        size: 16, color: theme.colorScheme.onSecondaryContainer),
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    labelStyle: TextStyle(color: theme.colorScheme.onSecondaryContainer),
                    label: Text(_isToday ? 'Today' : DateFormat('EEE d MMM').format(_date)),
                    onPressed: _pickDate,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SectionLabel(isTransfer ? 'From account' : 'Account'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 0,
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
                const SectionLabel('To account'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 0,
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
                const SectionLabel('Category'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 0,
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
              const SizedBox(height: 16),
              TextField(
                controller: _noteController,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: 20),
              _DaySummary(date: _dateOnly),
            ],
          ),
        ),
        // Save stays pinned at the bottom, always one thumb-tap away,
        // regardless of how far the form above is scrolled.
        Material(
          color: theme.colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: ListenableBuilder(
              listenable: _amountController,
              builder: (context, _) {
                final amount =
                    double.tryParse(_amountController.text.replaceAll(',', ''));
                final label = amount == null || amount <= 0
                    ? 'Save'
                    : 'Save ${formatMoney(amount, currency)}';
                return FilledButton.icon(
                  key: const ValueKey('save-button'),
                  onPressed: accounts.isEmpty ? null : () => _save(accounts),
                  icon: const Icon(Icons.check),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    textStyle:
                        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  label: Text(label),
                );
              },
            ),
          ),
        ),
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
            ? 'Amount received — leave empty to match'
            : 'Amount received',
        suffixText: to.currency,
        helperText: sameCurrency ? null : 'Currency exchange: enter what actually arrived',
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
    final theme = Theme.of(context);
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
          final currency =
              CurrencyX.fromCode(accountById[t.accountId]?.currency ?? 'UGX');
          totalUgx += convertWithRate(t.amount, currency, Currency.ugx, latestRate) ?? t.amount;
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(DateFormat('EEEE d MMMM').format(date),
                        style: theme.textTheme.titleSmall),
                    Text(
                      formatMoney(totalUgx, Currency.ugx),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                if (txs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('No entries yet for this day.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                for (final t in txs)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: KindAvatar(kind: t.kind, small: true),
                    title: Text(t.kind == TxKind.transfer
                        ? '${accountById[t.accountId]?.name ?? '?'} → ${accountById[t.toAccountId]?.name ?? '?'}'
                        : (categoryById[t.categoryId]?.name ?? 'Uncategorised')),
                    subtitle: t.note == null ? null : Text(t.note!),
                    trailing: Text(
                      formatMoney(
                        t.amount,
                        CurrencyX.fromCode(accountById[t.accountId]?.currency ?? 'UGX'),
                      ),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
