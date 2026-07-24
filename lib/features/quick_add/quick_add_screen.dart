import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../shared/widgets.dart';

/// Number of category chips shown inline; the rest live in the "All" sheet.
const _kQuickCategoryCount = 8;

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
  bool _excludeFromReport = false;

  @override
  void dispose() {
    _amountController.dispose();
    _toAmountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  DateTime get _dateOnly => DateTime.utc(_date.year, _date.month, _date.day);

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool get _isToday => _sameDay(_date, DateTime.now());

  String get _dateLabel {
    final now = DateTime.now();
    if (_isToday) return 'Today';
    if (_sameDay(_date, DateTime(now.year, now.month, now.day - 1))) {
      return 'Yesterday';
    }
    final format = _date.year == now.year
        ? DateFormat('EEE d MMM')
        : DateFormat('EEE d MMM yyyy');
    return format.format(_date);
  }

  void _shiftDate(int days) {
    setState(() => _date = DateTime(_date.year, _date.month, _date.day + days));
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
    final ledgerId = ref.read(selectedLedgerProvider);
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
        ledgerId: Value(ledgerId),
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
        excludeFromReport: Value(!isTransfer && _excludeFromReport),
        createdAt: now,
        updatedAt: now,
      ),
    );
    ref.read(lastAccountProvider.notifier).set(_accountId!);
    setState(() {
      _amountController.clear();
      _toAmountController.clear();
      _noteController.clear();
      _excludeFromReport = false;
      // Keep category/account/date selected: entering several similar rows
      // (or several rows for a past day) is common.
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

  /// Categories ranked by recent usage, most-used first; falls back to the
  /// user-defined sort order when counts tie (or no history exists yet).
  List<Category> _rankedCategories(
    List<Category> categories,
    Map<String, int> usage,
  ) {
    final ranked = [...categories]
      ..sort((a, b) {
        final byUsage = (usage[b.id] ?? 0).compareTo(usage[a.id] ?? 0);
        if (byUsage != 0) return byUsage;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    return ranked;
  }

  Future<void> _pickAccount({required bool destination}) async {
    final accounts = ref.read(accountsProvider).value ?? [];
    final options = destination
        ? accounts.where((a) => a.id != _accountId).toList()
        : accounts;
    final selectedId = destination ? _toAccountId : _accountId;
    final picked = await showModalBottomSheet<Account>(
      context: context,
      showDragHandle: true,
      builder: (context) => _AccountSheet(
        title: destination ? 'To account' : 'Account',
        accounts: options,
        selectedId: selectedId,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (destination) {
        _toAccountId = picked.id;
      } else {
        _accountId = picked.id;
        if (_toAccountId == picked.id) _toAccountId = null;
      }
    });
  }

  Future<void> _pickCategoryFromSheet(List<Category> categories) async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _CategorySheet(
        categories: _rankedCategories(
          categories,
          ref.read(categoryUsageProvider).value ?? {},
        ),
        selectedId: _categoryId,
      ),
    );
    if (picked != null) setState(() => _categoryId = picked.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final lastAccountId = ref.watch(lastAccountProvider);
    if (!accounts.any((a) => a.id == _accountId)) {
      _accountId = accounts.any((a) => a.id == lastAccountId)
          ? lastAccountId
          : (accounts.isNotEmpty ? accounts.first.id : null);
    }
    if (!accounts.any((a) => a.id == _toAccountId)) {
      _toAccountId = null;
    }
    if (!categories.any((c) => c.id == _categoryId)) {
      _categoryId = null;
    }

    final isTransfer = _kind == TxKind.transfer;
    final selectedAccount =
        accounts.where((a) => a.id == _accountId).firstOrNull ??
        accounts.firstOrNull;
    final toAccount = accounts.where((a) => a.id == _toAccountId).firstOrNull;

    // Quick chips: the most-used categories, with the selected one always
    // visible even when it normally ranks below the cutoff.
    final ranked = _rankedCategories(
      categories,
      ref.watch(categoryUsageProvider).value ?? {},
    );
    final quick = ranked.take(_kQuickCategoryCount).toList();
    final selected = ranked.where((c) => c.id == _categoryId).firstOrNull;
    if (selected != null && !quick.any((c) => c.id == selected.id)) {
      quick[quick.length - 1] = selected;
    }

    return ListView(
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
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              key: const ValueKey('date-back'),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous day',
              onPressed: () => _shiftDate(-1),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  _dateLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('date-forward'),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next day',
              onPressed: _isToday ? null : () => _shiftDate(1),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  hintText: '0',
                  labelText: isTransfer ? 'Amount sent' : 'Amount',
                  suffixText: selectedAccount?.currency,
                  suffixStyle: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const ValueKey('save-button'),
              onPressed: accounts.isEmpty ? null : () => _save(accounts),
              icon: const Icon(Icons.check),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                textStyle: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              label: const Text('Save'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SelectorTile(
          key: const ValueKey('account-selector'),
          icon: Icons.account_balance_wallet_outlined,
          label: isTransfer ? 'From account' : 'Account',
          value: selectedAccount == null
              ? 'Pick an account'
              : '${selectedAccount.name} · ${selectedAccount.currency}',
          onTap: () => _pickAccount(destination: false),
        ),
        if (isTransfer) ...[
          const SizedBox(height: 8),
          _SelectorTile(
            key: const ValueKey('to-account-selector'),
            icon: Icons.move_down,
            label: 'To account',
            value: toAccount == null
                ? 'Pick an account'
                : '${toAccount.name} · ${toAccount.currency}',
            onTap: () => _pickAccount(destination: true),
          ),
          const SizedBox(height: 12),
          _ToAmountField(
            accounts: accounts,
            fromId: _accountId,
            toId: _toAccountId,
            controller: _toAmountController,
          ),
        ] else ...[
          const SizedBox(height: 16),
          const SectionLabel('Category'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 0,
            children: [
              for (final c in quick)
                _CategoryChip(
                  category: c,
                  selected: _categoryId == c.id,
                  onSelected: (_) => setState(() => _categoryId = c.id),
                ),
              if (categories.length > quick.length)
                ActionChip(
                  key: const ValueKey('category-more'),
                  avatar: const Icon(Icons.grid_view, size: 16),
                  label: Text('All ${categories.length}'),
                  onPressed: () => _pickCategoryFromSheet(categories),
                ),
            ],
          ),
        ],
        if (!isTransfer)
          CheckboxListTile(
            key: const ValueKey('exclude-from-report'),
            value: _excludeFromReport,
            onChanged: (v) => setState(() => _excludeFromReport = v ?? false),
            title: Text(
              _kind == TxKind.income
                  ? 'Exclude from income'
                  : 'Exclude from expenses',
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _noteController,
          decoration: const InputDecoration(labelText: 'Note (optional)'),
        ),
        const SizedBox(height: 20),
        _DaySummary(date: _dateOnly),
      ],
    );
  }
}

/// Category chip with a small colour dot when the category has one.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.selected,
    required this.onSelected,
  });

  final Category category;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      avatar: category.color == null
          ? null
          : CircleAvatar(radius: 5, backgroundColor: Color(category.color!)),
      label: Text(category.name),
      selected: selected,
      onSelected: onSelected,
    );
  }
}

/// Compact one-line selector that opens a bottom sheet: icon, micro-label,
/// current value, and a chevron.
class _SelectorTile extends StatelessWidget {
  const _SelectorTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionLabel(label),
                    const SizedBox(height: 2),
                    Text(value, style: theme.textTheme.titleSmall),
                  ],
                ),
              ),
              Icon(
                Icons.expand_more,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet listing accounts; pops with the tapped account.
class _AccountSheet extends StatelessWidget {
  const _AccountSheet({
    required this.title,
    required this.accounts,
    required this.selectedId,
  });

  final String title;
  final List<Account> accounts;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final a in accounts)
                  ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(a.name),
                    subtitle: Text(a.currency),
                    trailing: a.id == selectedId
                        ? Icon(Icons.check, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(a),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Searchable bottom sheet with every category (most-used first); pops with
/// the tapped category.
class _CategorySheet extends StatefulWidget {
  const _CategorySheet({required this.categories, required this.selectedId});

  final List<Category> categories;
  final String? selectedId;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = widget.categories
        .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey('category-search'),
                  autofocus: false,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search categories',
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 0,
                    children: [
                      for (final c in matches)
                        _CategoryChip(
                          category: c,
                          selected: c.id == widget.selectedId,
                          onSelected: (_) => Navigator.of(context).pop(c),
                        ),
                      if (matches.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No categories match.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
        helperText: sameCurrency
            ? null
            : 'Currency exchange: enter what actually arrived',
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
    final ledgerId = ref.watch(selectedLedgerProvider);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    return StreamBuilder<List<Transaction>>(
      stream: db.watchTransactions(
        ledgerId: ledgerId,
        from: date,
        to: date,
        limit: 200,
      ),
      builder: (context, snapshot) {
        final txs = snapshot.data ?? [];
        final accountById = {for (final a in accounts) a.id: a};
        final categoryById = {for (final c in categories) c.id: c};
        double totalUgx = 0;
        final latestRate = ref.watch(latestRateProvider).value;
        for (final t in txs.where(
          (t) => t.kind == TxKind.expense && !t.excludeFromReport,
        )) {
          final currency = CurrencyX.fromCode(
            accountById[t.accountId]?.currency ?? 'UGX',
          );
          totalUgx +=
              convertWithRate(t.amount, currency, Currency.ugx, latestRate) ??
              t.amount;
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
                    Text(
                      DateFormat('EEEE d MMMM').format(date),
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      formatMoney(totalUgx, Currency.ugx),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (txs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No entries yet for this day.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final t in txs)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: KindAvatar(kind: t.kind, small: true),
                    title: Text(
                      t.kind == TxKind.transfer
                          ? '${accountById[t.accountId]?.name ?? '?'} → ${accountById[t.toAccountId]?.name ?? '?'}'
                          : (categoryById[t.categoryId]?.name ??
                                'Uncategorised'),
                    ),
                    subtitle: t.note == null ? null : Text(t.note!),
                    trailing: Text(
                      formatMoney(
                        t.amount,
                        CurrencyX.fromCode(
                          accountById[t.accountId]?.currency ?? 'UGX',
                        ),
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
