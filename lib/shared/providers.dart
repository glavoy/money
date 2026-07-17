import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/seed.dart';
import 'currency.dart';

const uuid = Uuid();

/// Overridden in main() with the opened database.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden');
});

final ledgersProvider = StreamProvider<List<Ledger>>((ref) {
  return ref.watch(databaseProvider).watchLedgers();
});

/// Ledger whose accounts, categories, transactions, and reports are visible.
class SelectedLedgerNotifier extends Notifier<String> {
  static const _key = 'selected_ledger_id';

  @override
  String build() {
    ref.watch(databaseProvider).getSetting(_key).then((value) async {
      final ledgers = await ref.read(databaseProvider).getLedgers();
      if (ledgers.any((l) => l.id == value)) {
        state = value!;
      } else if (ledgers.isNotEmpty) {
        state = ledgers.first.id;
        await ref.read(databaseProvider).setSetting(_key, state);
      }
    });
    return personalLedgerId;
  }

  void set(String ledgerId) {
    state = ledgerId;
    ref.read(databaseProvider).setSetting(_key, ledgerId);
  }
}

final selectedLedgerProvider = NotifierProvider<SelectedLedgerNotifier, String>(
  SelectedLedgerNotifier.new,
);

final accountsProvider = StreamProvider<List<Account>>((ref) {
  final ledgerId = ref.watch(selectedLedgerProvider);
  return ref.watch(databaseProvider).watchAccounts(ledgerId: ledgerId);
});

final balancesProvider = StreamProvider<List<AccountBalance>>((ref) {
  final ledgerId = ref.watch(selectedLedgerProvider);
  return ref.watch(databaseProvider).watchBalances(ledgerId: ledgerId);
});

final expenseCategoriesProvider = StreamProvider<List<Category>>((ref) {
  final ledgerId = ref.watch(selectedLedgerProvider);
  return ref
      .watch(databaseProvider)
      .watchCategories(ledgerId: ledgerId, kind: CategoryKind.expense);
});

final incomeCategoriesProvider = StreamProvider<List<Category>>((ref) {
  final ledgerId = ref.watch(selectedLedgerProvider);
  return ref
      .watch(databaseProvider)
      .watchCategories(ledgerId: ledgerId, kind: CategoryKind.income);
});

final allCategoriesProvider = StreamProvider<List<Category>>((ref) {
  final ledgerId = ref.watch(selectedLedgerProvider);
  return ref
      .watch(databaseProvider)
      .watchCategories(ledgerId: ledgerId, includeArchived: true);
});

/// How often each category was used in the last 90 days, so Quick Add can
/// surface the most-used ones first and tuck the rest behind "All".
final categoryUsageProvider = StreamProvider<Map<String, int>>((ref) {
  final ledgerId = ref.watch(selectedLedgerProvider);
  final now = DateTime.now();
  final from = DateTime.utc(now.year, now.month, now.day - 90);
  return ref
      .watch(databaseProvider)
      .watchTransactions(ledgerId: ledgerId, from: from, limit: 2000)
      .map((txs) {
        final counts = <String, int>{};
        for (final t in txs) {
          final id = t.categoryId;
          if (id != null) counts[id] = (counts[id] ?? 0) + 1;
        }
        return counts;
      });
});

final latestRateProvider = StreamProvider<FxRate?>((ref) {
  return ref.watch(databaseProvider).watchLatestRate();
});

/// Enables the one-off startup fetch for today's exchange rate.
///
/// Tests override this to avoid live network calls while pumping the app.
final autoFetchTodayRateProvider = Provider<bool>((ref) => true);

/// Currency used for reports and totals; persisted in app settings.
class DisplayCurrencyNotifier extends Notifier<Currency> {
  static const _key = 'display_currency';

  @override
  Currency build() {
    ref.watch(databaseProvider).getSetting(_key).then((value) {
      if (value != null) state = CurrencyX.fromCode(value);
    });
    return Currency.ugx;
  }

  void set(Currency currency) {
    state = currency;
    ref.read(databaseProvider).setSetting(_key, currency.code);
  }
}

final displayCurrencyProvider =
    NotifierProvider<DisplayCurrencyNotifier, Currency>(
      DisplayCurrencyNotifier.new,
    );

/// App theme preference; persisted in app settings.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    ref.watch(databaseProvider).getSetting(_key).then((value) {
      if (value != null) state = _fromSetting(value);
    });
    return ThemeMode.system;
  }

  void set(ThemeMode mode) {
    state = mode;
    ref.read(databaseProvider).setSetting(_key, _toSetting(mode));
  }

  ThemeMode _fromSetting(String value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  String _toSetting(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

/// Account preselected on the Quick Add screen; persisted in app settings.
class LastAccountNotifier extends Notifier<String?> {
  static const _key = 'last_account_id';

  @override
  String? build() {
    ref.watch(databaseProvider).getSetting(_key).then((value) {
      if (value != null) state = value;
    });
    return null;
  }

  void set(String accountId) {
    state = accountId;
    ref.read(databaseProvider).setSetting(_key, accountId);
  }
}

final lastAccountProvider = NotifierProvider<LastAccountNotifier, String?>(
  LastAccountNotifier.new,
);
