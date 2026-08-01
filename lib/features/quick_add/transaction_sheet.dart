import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../sync/sync_service.dart';

/// Which amount line the keypad is currently driving. Only cross-currency
/// transfers ever show a second line.
enum _Field { amount, toAmount }

// Every row above the category grid is a fixed height, so that switching
// kind, currency or note visibility cannot shift any control. The grid is
// the single flexible region and absorbs all the slack.
const _kAmountBlockHeight = 84.0;
const _kKindSelectorHeight = 48.0;
const _kControlsRowHeight = 48.0;
const _kKeypadHeight = 232.0;

/// Stands in for the keypad when the system keyboard has replaced it, so
/// Save is reachable in every state.
const _kSaveBarHeight = 52.0;

/// Below this the keypad is too cramped to use, so it yields entirely.
const _kMinKeypadHeight = 150.0;

/// Budget allowance for the note field — not forced on the field itself.
const _kNoteAllowance = 64.0;

/// Roughly one row of tiles — the grid never collapses to nothing.
const _kMinGridHeight = 56.0;

/// The sheet stops growing here rather than filling a tall desktop window.
/// 180 chrome + 232 keypad + ~260 of grid.
const _kPreferredSheetHeight = 680.0;

/// Category/account tile row height, fixed so row counts are predictable at
/// any sheet width (the modal is capped at 640 wide on desktop).
const _kCategoryTileHeight = 44.0;
const _kAccountTileHeight = 48.0;

final _letter = RegExp(r'^[A-Za-z]$');
final _filterContinuation = RegExp(r'^[A-Za-z0-9 _.\-]$');

/// Numpad digits need spelling out: `numpad1.keyLabel` is "Numpad 1".
final _kDigitKeys = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.digit0: '0',
  LogicalKeyboardKey.digit1: '1',
  LogicalKeyboardKey.digit2: '2',
  LogicalKeyboardKey.digit3: '3',
  LogicalKeyboardKey.digit4: '4',
  LogicalKeyboardKey.digit5: '5',
  LogicalKeyboardKey.digit6: '6',
  LogicalKeyboardKey.digit7: '7',
  LogicalKeyboardKey.digit8: '8',
  LogicalKeyboardKey.digit9: '9',
  LogicalKeyboardKey.numpad0: '0',
  LogicalKeyboardKey.numpad1: '1',
  LogicalKeyboardKey.numpad2: '2',
  LogicalKeyboardKey.numpad3: '3',
  LogicalKeyboardKey.numpad4: '4',
  LogicalKeyboardKey.numpad5: '5',
  LogicalKeyboardKey.numpad6: '6',
  LogicalKeyboardKey.numpad7: '7',
  LogicalKeyboardKey.numpad8: '8',
  LogicalKeyboardKey.numpad9: '9',
};

/// The app's single transaction entry surface, for both new entries and
/// edits. Pass [tx] to edit an existing row; leave it null to create one.
///
/// [initialAccountId] and [initialKind] seed a new entry — e.g. opening this
/// from an account's ledger pre-selects that account. Both are ignored when
/// editing, since the existing row supplies them.
Future<void> showTransactionSheet(
  BuildContext context,
  WidgetRef ref, {
  Transaction? tx,
  String? initialAccountId,
  String? initialKind,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _TransactionSheet(
      tx: tx,
      initialAccountId: initialAccountId,
      initialKind: initialKind,
    ),
  );
}

Future<bool> confirmDeleteTransaction(
  BuildContext context,
  String title,
  String amount,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete entry?'),
          content: Text('$title — $amount'),
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
}

Future<void> deleteTransactionWithSync(WidgetRef ref, String id) async {
  await ref.read(databaseProvider).softDeleteTransaction(id);
  ref.read(syncServiceProvider).syncSilently();
}

class _TransactionSheet extends ConsumerStatefulWidget {
  const _TransactionSheet({
    required this.tx,
    required this.initialAccountId,
    required this.initialKind,
  });

  final Transaction? tx;
  final String? initialAccountId;
  final String? initialKind;

  @override
  ConsumerState<_TransactionSheet> createState() => _TransactionSheetState();
}

class _TransactionSheetState extends ConsumerState<_TransactionSheet> {
  late String _kind;
  late DateTime _date;
  late String _amountText;
  late String _toAmountText;
  late bool _excludeFromReport;
  final _noteController = TextEditingController();
  final _noteFocus = FocusNode(debugLabel: 'transaction-sheet-note');
  final _keyFocus = FocusNode(debugLabel: 'transaction-sheet-keys');

  String? _accountId;
  String? _toAccountId;
  String? _categoryId;
  var _activeField = _Field.amount;
  var _showNote = false;

  /// Typed on a physical keyboard to narrow the category grid. Always empty
  /// on a touch device, where it is never shown.
  var _filter = '';

  bool get _isEditing => widget.tx != null;
  bool get _isTransfer => _kind == TxKind.transfer;
  DateTime get _dateOnly => DateTime.utc(_date.year, _date.month, _date.day);

  @override
  void initState() {
    super.initState();
    final tx = widget.tx;
    _kind = tx?.kind ?? widget.initialKind ?? TxKind.expense;
    _date = tx?.date ?? DateTime.now();
    _amountText = tx == null ? '' : trimmedAmount(tx.amount);
    _toAmountText = tx?.toAmount == null ? '' : trimmedAmount(tx!.toAmount!);
    _excludeFromReport = tx?.excludeFromReport ?? false;
    _noteController.text = tx?.note ?? '';
    _showNote = (tx?.note ?? '').isNotEmpty;
    _accountId = tx?.accountId ?? widget.initialAccountId;
    _toAccountId = tx?.toAccountId;
    _categoryId = tx?.categoryId;
  }

  @override
  void dispose() {
    _keyFocus.dispose();
    _noteFocus.dispose();
    _noteController.dispose();
    super.dispose();
  }

  /// Take keyboard focus back after a dialog or picker returns.
  void _refocusKeys() {
    if (mounted && !_noteFocus.hasFocus) _keyFocus.requestFocus();
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
    return [...categories]..sort((a, b) {
      final byUsage = (usage[b.id] ?? 0).compareTo(usage[a.id] ?? 0);
      if (byUsage != 0) return byUsage;
      return a.sortOrder.compareTo(b.sortOrder);
    });
  }

  void _tapKey(String key) {
    setState(() {
      final current = _activeField == _Field.amount
          ? _amountText
          : _toAmountText;
      var next = current;
      if (key == _kBackspace) {
        next = current.isEmpty ? '' : current.substring(0, current.length - 1);
      } else if (key == '.') {
        if (!current.contains('.')) next = current.isEmpty ? '0.' : '$current.';
      } else {
        if (current.contains('.')) {
          // Money is at most 2dp; ignore digits that would overflow it.
          final decimals = current.split('.')[1].length;
          if (decimals + key.length > 2) return;
        }
        next = current + key;
        // Strip the leading zero left by typing onto a bare "0".
        if (next.length > 1 && next.startsWith('0') && !next.startsWith('0.')) {
          next = next.replaceFirst(RegExp(r'^0+'), '');
          if (next.isEmpty) next = '0';
        }
      }
      if (_activeField == _Field.amount) {
        _amountText = next;
      } else {
        _toAmountText = next;
      }
    });
  }

  /// Physical-keyboard input, for the desktop builds where there is no touch
  /// keypad. Digits drive the amount, letters narrow the grid.
  KeyEventResult _onKey(
    KeyEvent event, {
    required List<Account> accounts,
    required bool allowDecimal,
    required List<Category> visibleCategories,
    required List<Account> visibleAccounts,
  }) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // While a note is being typed the text field owns the keyboard.
    if (_noteFocus.hasFocus) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed || hw.isMetaPressed || hw.isAltPressed) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final digit = _kDigitKeys[key];
    if (digit != null) {
      _tapKey(digit);
      return KeyEventResult.handled;
    }
    if (allowDecimal &&
        (key == LogicalKeyboardKey.period ||
            key == LogicalKeyboardKey.numpadDecimal)) {
      _tapKey('.');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      // Whatever was typed most recently is what backspace edits, and the
      // filter chip makes which one that is visible.
      if (_filter.isNotEmpty) {
        setState(() => _filter = _filter.substring(0, _filter.length - 1));
      } else {
        _tapKey(_kBackspace);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // While filtering, Enter takes the top match; a second Enter saves.
      if (_filter.isNotEmpty) {
        if (_isTransfer && visibleAccounts.isNotEmpty) {
          _pickDestination(visibleAccounts.first);
          return KeyEventResult.handled;
        }
        if (!_isTransfer && visibleCategories.isNotEmpty) {
          setState(() {
            _categoryId = visibleCategories.first.id;
            _filter = '';
          });
          return KeyEventResult.handled;
        }
      }
      _save(accounts);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_filter.isEmpty) {
        // The modal route's own dismiss action closes the sheet.
        return KeyEventResult.ignored;
      }
      setState(() => _filter = '');
      return KeyEventResult.handled;
    }

    // `character` is layout-dependent and null under simulated key events,
    // so fall back to the key label to stay deterministic.
    final typed = _typedCharacter(event);
    if (typed != null) {
      if (_letter.hasMatch(typed)) {
        setState(() => _filter += typed.toLowerCase());
        return KeyEventResult.handled;
      }
      // Digits and space keep their primary meaning until a filter exists;
      // after that they can continue names like "beer_r" or "Rent income".
      if (_filter.isNotEmpty && _filterContinuation.hasMatch(typed)) {
        setState(() => _filter += typed.toLowerCase());
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  static String? _typedCharacter(KeyEvent event) {
    final character = event.character;
    if (character != null && character.length == 1) return character;
    final label = event.logicalKey.keyLabel;
    return label.length == 1 ? label : null;
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
    _refocusKeys();
  }

  Future<void> _pickAccount(List<Account> accounts) async {
    final picked = await showModalBottomSheet<Account>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final a in accounts)
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(a.name),
                subtitle: Text(a.currency),
                trailing: a.id == _accountId
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(context, a),
              ),
          ],
        ),
      ),
    );
    _refocusKeys();
    if (picked == null) return;
    setState(() {
      _accountId = picked.id;
      if (_toAccountId == picked.id) _toAccountId = null;
    });
  }

  Future<void> _save(List<Account> accounts) async {
    final amount = double.tryParse(_amountText);
    if (amount == null || amount <= 0) {
      _toast('Enter an amount');
      return;
    }
    if (_accountId == null) {
      _toast('Pick an account');
      return;
    }
    if (!_isTransfer && _categoryId == null) {
      _toast('Pick a category');
      return;
    }

    double? toAmount;
    if (_isTransfer) {
      if (_toAccountId == null || _toAccountId == _accountId) {
        _toast('Pick a destination account');
        return;
      }
      final from = accounts.firstWhere((a) => a.id == _accountId);
      final to = accounts.firstWhere((a) => a.id == _toAccountId);
      if (from.currency == to.currency) {
        toAmount = double.tryParse(_toAmountText) ?? amount;
      } else {
        toAmount = double.tryParse(_toAmountText);
        if (toAmount == null || toAmount <= 0) {
          _toast('Enter the amount received (${to.currency})');
          return;
        }
      }
    }

    final note = _noteController.text.trim();
    final now = DateTime.now().toUtc();
    final tx = widget.tx;
    await ref
        .read(databaseProvider)
        .upsertTransaction(
          TransactionsCompanion.insert(
            id: tx?.id ?? uuid.v4(),
            ledgerId: Value(tx?.ledgerId ?? ref.read(selectedLedgerProvider)),
            date: _dateOnly,
            kind: _kind,
            amount: amount,
            accountId: _accountId!,
            categoryId: Value(_isTransfer ? null : _categoryId),
            toAccountId: Value(_isTransfer ? _toAccountId : null),
            toAmount: Value(toAmount),
            note: Value(note.isEmpty ? null : note),
            excludeFromReport: Value(!_isTransfer && _excludeFromReport),
            createdAt: tx?.createdAt ?? now,
            updatedAt: now,
          ),
        );
    ref.read(lastAccountProvider.notifier).set(_accountId!);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete(Currency currency) async {
    final tx = widget.tx!;
    final confirmed = await confirmDeleteTransaction(
      context,
      _isTransfer ? 'Transfer' : 'Entry',
      formatMoney(tx.amount, currency),
    );
    if (!confirmed) return;
    await deleteTransactionWithSync(ref, tx.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final pickable = ref.watch(accountsProvider).value ?? [];
    final allAccounts = ref.watch(allAccountsProvider).value ?? [];
    final categories =
        ref
            .watch(
              _kind == TxKind.income
                  ? incomeCategoriesProvider
                  : expenseCategoriesProvider,
            )
            .value ??
        [];

    // Seed the account the way Quick Add used to: last used, else the first.
    final lastAccountId = ref.watch(lastAccountProvider);
    if (!allAccounts.any((a) => a.id == _accountId)) {
      _accountId = pickable.any((a) => a.id == lastAccountId)
          ? lastAccountId
          : (pickable.isNotEmpty ? pickable.first.id : null);
    }
    if (_categoryId != null && !categories.any((c) => c.id == _categoryId)) {
      _categoryId = null;
    }

    final account = allAccounts.where((a) => a.id == _accountId).firstOrNull;
    final toAccount = allAccounts
        .where((a) => a.id == _toAccountId)
        .firstOrNull;
    final currency = CurrencyX.fromCode(account?.currency ?? 'UGX');
    final toCurrency = CurrencyX.fromCode(toAccount?.currency ?? 'UGX');
    final crossCurrency =
        _isTransfer && toAccount != null && currency != toCurrency;

    // A same-currency destination hides the second amount line, so make sure
    // the keypad is not still aimed at it.
    if (!crossCurrency && _activeField == _Field.toAmount) {
      _activeField = _Field.amount;
    }

    // Filtering happens here rather than inside the grids, because the key
    // handler needs the same visible list for Enter-to-pick.
    final ranked = _rankedCategories(
      categories,
      ref.watch(categoryUsageProvider).value ?? {},
    );
    final visibleCategories = _filter.isEmpty
        ? ranked
        : ranked.where((c) => c.name.toLowerCase().contains(_filter)).toList();
    final visibleAccounts = pickable
        .where(
          (a) =>
              a.id != _accountId &&
              (_filter.isEmpty || a.name.toLowerCase().contains(_filter)),
        )
        .toList();
    final noMatch =
        _filter.isNotEmpty &&
        (_isTransfer ? visibleAccounts : visibleCategories).isEmpty;

    final bottomPad = media.padding.bottom > 0 ? 8.0 : 12.0;
    final noteAllowance = _showNote ? _kNoteAllowance : 0.0;

    // Height depends only on the window and the system keyboard — never on
    // the content — so switching kind/currency/note cannot move a control.
    // showDragHandle adds kMinInteractiveDimension above everything here.
    final available = math.min(
      media.size.height * 0.9,
      media.size.height - media.viewInsets.bottom - kMinInteractiveDimension,
    );
    final sheetHeight = math.min(_kPreferredSheetHeight, available);

    // The keypad is what gives way when space is short — to the note field
    // and the grid's floor — rather than letting anything overflow.
    final fixedChrome =
        _kAmountBlockHeight + _kKindSelectorHeight + _kControlsRowHeight;
    final keypadHeight = math.min(
      _kKeypadHeight,
      math.max(
        0.0,
        sheetHeight - fixedChrome - bottomPad - noteAllowance - _kMinGridHeight,
      ),
    );
    final showKeypad = keypadHeight >= _kMinKeypadHeight;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Focus(
        // An ancestor of everything in the sheet, so key events bubble here
        // whichever chip or tile holds focus — and, unlike a global handler,
        // it stops receiving them while a date/account dialog is open.
        focusNode: _keyFocus,
        autofocus: true,
        onKeyEvent: (node, event) => _onKey(
          event,
          accounts: allAccounts,
          allowDecimal: currency != Currency.ugx || crossCurrency,
          visibleCategories: visibleCategories,
          visibleAccounts: visibleAccounts,
        ),
        child: SizedBox(
          key: const ValueKey('sheet-body'),
          height: sheetHeight,
          child: Column(
            children: [
              SizedBox(
                height: _kAmountBlockHeight,
                child: _amountDisplay(
                  theme,
                  currency,
                  toCurrency,
                  crossCurrency,
                ),
              ),
              SizedBox(
                height: _kKindSelectorHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(child: _kindSelector()),
                ),
              ),
              SizedBox(
                height: _kControlsRowHeight,
                child: _metaRow(theme, account, pickable, currency, noMatch),
              ),
              // Everything variable lives here, so nothing above it moves.
              Expanded(
                child: Column(
                  children: [
                    if (_showNote)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: TextField(
                          controller: _noteController,
                          focusNode: _noteFocus,
                          decoration: const InputDecoration(
                            labelText: 'Note',
                            isDense: true,
                          ),
                        ),
                      ),
                    Expanded(
                      child: _isTransfer
                          ? _accountGrid(theme, visibleAccounts)
                          : _categoryGrid(theme, visibleCategories),
                    ),
                  ],
                ),
              ),
              if (showKeypad)
                SizedBox(
                  height: keypadHeight,
                  child: _Keypad(
                    allowDecimal: currency != Currency.ugx || crossCurrency,
                    onKey: _tapKey,
                    onSave: () => _save(allAccounts),
                    saveLabel: _isEditing ? 'Update' : 'Save',
                  ),
                )
              else
                SizedBox(
                  height: _kSaveBarHeight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                    child: FilledButton(
                      key: const ValueKey('save-button'),
                      onPressed: () => _save(allAccounts),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: Text(_isEditing ? 'Update' : 'Save'),
                    ),
                  ),
                ),
              SizedBox(height: bottomPad),
            ],
          ),
        ),
      ),
    );
  }

  /// Shown identically when creating and editing, so the two layouts match.
  Widget _kindSelector() {
    return SegmentedButton<String>(
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
        _activeField = _Field.amount;
        _filter = '';
      }),
    );
  }

  Widget _amountDisplay(
    ThemeData theme,
    Currency currency,
    Currency toCurrency,
    bool crossCurrency,
  ) {
    final color = switch (_kind) {
      TxKind.income => theme.colorScheme.tertiary,
      TxKind.transfer => theme.colorScheme.onSurface,
      _ => theme.colorScheme.error,
    };
    final sign = switch (_kind) {
      TxKind.income => '+',
      TxKind.transfer => '',
      _ => '−',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: () => setState(() => _activeField = _Field.amount),
            child: Text(
              '$sign${_grouped(_amountText)} ${currency.code}',
              key: const ValueKey('amount-display'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
                decoration: crossCurrency && _activeField == _Field.amount
                    ? TextDecoration.underline
                    : null,
              ),
            ),
          ),
          if (crossCurrency)
            GestureDetector(
              onTap: () => setState(() => _activeField = _Field.toAmount),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'received ${_grouped(_toAmountText)} ${toCurrency.code}',
                  key: const ValueKey('to-amount-display'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    decoration: _activeField == _Field.toAmount
                        ? TextDecoration.underline
                        : null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _metaChips(ThemeData theme, Account? account, List<Account> pickable) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('date-back'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous day',
              onPressed: () => _shiftDate(-1),
            ),
            ActionChip(label: Text(_dateLabel), onPressed: _pickDate),
            IconButton(
              key: const ValueKey('date-forward'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next day',
              onPressed: _isToday ? null : () => _shiftDate(1),
            ),
            const SizedBox(width: 4),
            // The currency is already on the amount line above, so the chip
            // only needs the name — which keeps it narrow on a phone.
            ActionChip(
              key: const ValueKey('account-chip'),
              avatar: const Icon(
                Icons.account_balance_wallet_outlined,
                size: 16,
              ),
              label: Text(account?.name ?? 'Account'),
              onPressed: () => _pickAccount(pickable),
            ),
          ],
        ),
      ),
    );
  }

  /// Date and account scroll; the toggles and actions are pinned right, so
  /// they stay reachable on a narrow phone where the chips would overflow.
  Widget _metaRow(
    ThemeData theme,
    Account? account,
    List<Account> pickable,
    Currency currency,
    bool noMatch,
  ) {
    return Row(
      children: [
        Expanded(child: _metaChips(theme, account, pickable)),
        if (_filter.isNotEmpty)
          InputChip(
            key: const ValueKey('category-filter-chip'),
            label: Text(noMatch ? '$_filter · no match' : _filter),
            onDeleted: () => setState(() => _filter = ''),
          ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Note',
          isSelected: _showNote,
          icon: const Icon(Icons.sticky_note_2_outlined),
          selectedIcon: const Icon(Icons.sticky_note_2),
          onPressed: _toggleNote,
        ),
        if (!_isTransfer)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: _kind == TxKind.income
                ? 'Exclude from income'
                : 'Exclude from expenses',
            isSelected: _excludeFromReport,
            icon: const Icon(Icons.visibility_outlined),
            selectedIcon: const Icon(Icons.visibility_off),
            onPressed: () =>
                setState(() => _excludeFromReport = !_excludeFromReport),
          ),
        if (_isEditing)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Delete entry',
            color: theme.colorScheme.error,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(currency),
          ),
      ],
    );
  }

  void _toggleNote() {
    setState(() => _showNote = !_showNote);
    if (_showNote) {
      _noteFocus.requestFocus();
    } else {
      _noteFocus.unfocus();
      _keyFocus.requestFocus();
    }
  }

  Widget _emptyGrid(ThemeData theme, String emptyMessage) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _filter.isEmpty ? emptyMessage : 'Nothing matches "$_filter"',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _categoryGrid(ThemeData theme, List<Category> ranked) {
    if (ranked.isEmpty) {
      return _emptyGrid(theme, 'No categories yet');
    }
    return GridView.builder(
      key: const ValueKey('category-grid'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        mainAxisExtent: _kCategoryTileHeight,
      ),
      itemCount: ranked.length,
      itemBuilder: (context, i) {
        final c = ranked[i];
        return _GridTile(
          label: c.name,
          selected: c.id == _categoryId,
          color: c.color == null ? null : Color(c.color!),
          onTap: () => setState(() {
            _categoryId = c.id;
            _filter = '';
          }),
        );
      },
    );
  }

  Widget _accountGrid(ThemeData theme, List<Account> options) {
    if (options.isEmpty) {
      return _emptyGrid(theme, 'No other accounts');
    }
    return GridView.builder(
      key: const ValueKey('account-grid'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        mainAxisExtent: _kAccountTileHeight,
      ),
      itemCount: options.length,
      itemBuilder: (context, i) {
        final a = options[i];
        return _GridTile(
          label: 'To ${a.name}',
          selected: a.id == _toAccountId,
          onTap: () => _pickDestination(a),
        );
      },
    );
  }

  void _pickDestination(Account a) {
    setState(() {
      _toAccountId = a.id;
      _activeField = _Field.amount;
      _filter = '';
    });
  }

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
}

const _kBackspace = '⌫';
final _groupFormat = NumberFormat('#,##0', 'en_US');

/// Groups the integer part of a part-typed amount, leaving any decimals the
/// user has entered so far untouched ("1234.5" -> "1,234.5").
String _grouped(String raw) {
  if (raw.isEmpty) return '0';
  final parts = raw.split('.');
  final whole = int.tryParse(parts.first.isEmpty ? '0' : parts.first) ?? 0;
  final grouped = _groupFormat.format(whole);
  return parts.length == 1 ? grouped : '$grouped.${parts[1]}';
}

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Tinted, so the things you pick read differently from the neutral grey
    // keypad keys below them.
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.primaryContainer.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (color != null) ...[
                CircleAvatar(radius: 4, backgroundColor: color),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface,
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

/// Numeric keypad. Replaces the system keyboard so the whole entry form fits
/// on screen without scrolling.
class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.allowDecimal,
    required this.onKey,
    required this.onSave,
    required this.saveLabel,
  });

  final bool allowDecimal;
  final ValueChanged<String> onKey;
  final VoidCallback onSave;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget key(String label, {String? value, bool enabled = true}) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: enabled ? 0.7 : 0.25,
            ),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: ValueKey('key-${value ?? label}'),
              borderRadius: BorderRadius.circular(10),
              onTap: enabled ? () => onKey(value ?? label) : null,
              child: Center(
                child: Text(
                  label,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? theme.colorScheme.onSurface
                        : Colors.transparent,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget row(List<Widget> children) =>
        Expanded(child: Row(children: children));

    // The parent owns the height so the keypad can shrink rather than force
    // the sheet to grow.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
                row([key('1'), key('2'), key('3')]),
                row([key('4'), key('5'), key('6')]),
                row([key('7'), key('8'), key('9')]),
                row([key('.', enabled: allowDecimal), key('0'), key('000')]),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Expanded(child: Row(children: [key(_kBackspace)])),
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: FilledButton(
                      key: const ValueKey('save-button'),
                      onPressed: onSave,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(saveLabel),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
