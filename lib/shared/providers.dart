import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'currency.dart';

const uuid = Uuid();

/// Overridden in main() with the opened database.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden');
});

final accountsProvider = StreamProvider<List<Account>>((ref) {
  return ref.watch(databaseProvider).watchAccounts();
});

final balancesProvider = StreamProvider<List<AccountBalance>>((ref) {
  return ref.watch(databaseProvider).watchBalances();
});

final expenseCategoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref
      .watch(databaseProvider)
      .watchCategories(kind: CategoryKind.expense);
});

final incomeCategoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref.watch(databaseProvider).watchCategories(kind: CategoryKind.income);
});

final allCategoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref.watch(databaseProvider).watchCategories(includeArchived: true);
});

final latestRateProvider = StreamProvider<FxRate?>((ref) {
  return ref.watch(databaseProvider).watchLatestRate();
});

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
