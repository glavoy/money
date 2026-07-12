import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'seed.dart';

part 'database.g.dart';

/// Account types.
class AccountType {
  static const cash = 'cash';
  static const bank = 'bank';
  static const mobileMoney = 'mobile_money';
  static const creditCard = 'credit_card';
}

/// Transaction kinds.
class TxKind {
  static const expense = 'expense';
  static const income = 'income';
  static const transfer = 'transfer';
}

/// Category kinds.
class CategoryKind {
  static const expense = 'expense';
  static const income = 'income';
}

/// FX rate sources, in ascending priority (manual beats api beats import).
class FxSource {
  static const import = 'import';
  static const api = 'api';
  static const manual = 'manual';
}

class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get currency => text()(); // UGX | USD | CAD
  RealColumn get openingBalance => real().withDefault(const Constant(0))();
  DateTimeColumn get openingDate => dateTime().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // expense | income
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get color => integer().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Transactions extends Table {
  TextColumn get id => text()();
  DateTimeColumn get date => dateTime()();
  TextColumn get kind => text()(); // expense | income | transfer
  RealColumn get amount => real()(); // in the account's currency
  TextColumn get accountId => text()();
  TextColumn get categoryId => text().nullable()(); // null for transfers
  TextColumn get toAccountId => text().nullable()(); // transfers only
  RealColumn get toAmount => real().nullable()(); // transfers only
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class FxRates extends Table {
  TextColumn get id => text()();
  DateTimeColumn get date => dateTime()();
  RealColumn get usdUgx => real().nullable()();
  RealColumn get cadUgx => real().nullable()();
  RealColumn get usdCad => real().nullable()();
  TextColumn get source =>
      text().withDefault(const Constant(FxSource.manual))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {date},
  ];
}

/// Simple key/value store for app settings and sync bookkeeping.
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Balance of one account, as computed from opening balance + transactions.
class AccountBalance {
  const AccountBalance({required this.account, required this.balance});

  final Account account;
  final double balance;
}

@DriftDatabase(
  tables: [Accounts, Categories, Transactions, FxRates, AppSettings],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  AppDatabase.open() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedDatabase(this);
    },
  );

  // ---------------------------------------------------------------------
  // Accounts
  // ---------------------------------------------------------------------

  Stream<List<Account>> watchAccounts({bool includeArchived = false}) {
    final q = select(accounts)
      ..where((a) => a.deleted.equals(false))
      ..orderBy([
        (a) => OrderingTerm.asc(a.sortOrder),
        (a) => OrderingTerm.asc(a.name),
      ]);
    if (!includeArchived) {
      q.where((a) => a.archived.equals(false));
    }
    return q.watch();
  }

  Future<List<Account>> getAccounts({bool includeArchived = false}) =>
      watchAccounts(includeArchived: includeArchived).first;

  /// Watches computed balances for all non-deleted accounts.
  Stream<List<AccountBalance>> watchBalances({bool includeArchived = false}) {
    final query = customSelect(
      '''
      SELECT a.id AS account_id,
             a.opening_balance
             + COALESCE((SELECT SUM(CASE t.kind
                                    WHEN 'income' THEN t.amount
                                    ELSE -t.amount END)
                         FROM transactions t
                         WHERE t.account_id = a.id AND t.deleted = 0), 0)
             + COALESCE((SELECT SUM(t.to_amount)
                         FROM transactions t
                         WHERE t.to_account_id = a.id AND t.deleted = 0), 0)
             AS balance
      FROM accounts a
      WHERE a.deleted = 0
      ''',
      readsFrom: {accounts, transactions},
    );
    return query.watch().asyncMap((rows) async {
      final byId = {
        for (final a in await getAccounts(includeArchived: true)) a.id: a,
      };
      final result = <AccountBalance>[];
      for (final row in rows) {
        final account = byId[row.read<String>('account_id')];
        if (account == null) continue;
        if (!includeArchived && account.archived) continue;
        result.add(
          AccountBalance(
            account: account,
            balance: row.read<double>('balance'),
          ),
        );
      }
      result.sort((a, b) => a.account.sortOrder.compareTo(b.account.sortOrder));
      return result;
    });
  }

  // ---------------------------------------------------------------------
  // Categories
  // ---------------------------------------------------------------------

  Stream<List<Category>> watchCategories({
    String? kind,
    bool includeArchived = false,
  }) {
    final q = select(categories)
      ..where((c) => c.deleted.equals(false))
      ..orderBy([
        (c) => OrderingTerm.asc(c.sortOrder),
        (c) => OrderingTerm.asc(c.name),
      ]);
    if (kind != null) {
      q.where((c) => c.kind.equals(kind));
    }
    if (!includeArchived) {
      q.where((c) => c.archived.equals(false));
    }
    return q.watch();
  }

  Future<List<Category>> getCategories({
    String? kind,
    bool includeArchived = false,
  }) => watchCategories(kind: kind, includeArchived: includeArchived).first;

  Future<int> countTransactionsForCategory(String categoryId) async {
    final query = selectOnly(transactions)
      ..addColumns([transactions.id.count()])
      ..where(
        transactions.deleted.equals(false) &
            transactions.categoryId.equals(categoryId),
      );
    return await query
        .map((row) => row.read(transactions.id.count()) ?? 0)
        .getSingle();
  }

  Future<bool> softDeleteCategoryIfUnused(String id) async {
    final count = await countTransactionsForCategory(id);
    if (count > 0) return false;
    await (update(categories)..where((c) => c.id.equals(id))).write(
      CategoriesCompanion(
        deleted: const Value(true),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    return true;
  }

  // ---------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------

  Stream<List<Transaction>> watchTransactions({
    DateTime? from,
    DateTime? to,
    String? accountId,
    String? categoryId,
    String? kind,
    int limit = 500,
  }) {
    final q = select(transactions)
      ..where((t) => t.deleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.desc(t.date),
        (t) => OrderingTerm.desc(t.createdAt),
      ])
      ..limit(limit);
    if (from != null) q.where((t) => t.date.isBiggerOrEqualValue(from));
    if (to != null) q.where((t) => t.date.isSmallerOrEqualValue(to));
    if (accountId != null) {
      q.where(
        (t) => t.accountId.equals(accountId) | t.toAccountId.equals(accountId),
      );
    }
    if (categoryId != null) q.where((t) => t.categoryId.equals(categoryId));
    if (kind != null) q.where((t) => t.kind.equals(kind));
    return q.watch();
  }

  Future<List<Transaction>> getTransactionsBetween(DateTime from, DateTime to) {
    final q = select(transactions)
      ..where(
        (t) =>
            t.deleted.equals(false) &
            t.date.isBiggerOrEqualValue(from) &
            t.date.isSmallerOrEqualValue(to),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.date)]);
    return q.get();
  }

  /// Inserts or replaces, bumping updated_at so sync picks it up.
  Future<void> upsertTransaction(TransactionsCompanion companion) async {
    await into(transactions).insertOnConflictUpdate(
      companion.copyWith(updatedAt: Value(DateTime.now().toUtc())),
    );
  }

  Future<void> softDeleteTransaction(String id) async {
    await (update(transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        deleted: const Value(true),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // FX rates
  // ---------------------------------------------------------------------

  Future<FxRate?> getRateOn(DateTime date) async {
    final day = DateTime.utc(date.year, date.month, date.day);
    final q = select(fxRates)
      ..where(
        (r) => r.deleted.equals(false) & r.date.isSmallerOrEqualValue(day),
      )
      ..orderBy([(r) => OrderingTerm.desc(r.date)])
      ..limit(1);
    return q.getSingleOrNull();
  }

  Future<List<FxRate>> getRatesBetween(DateTime from, DateTime to) {
    final q = select(fxRates)
      ..where(
        (r) =>
            r.deleted.equals(false) &
            r.date.isBiggerOrEqualValue(from) &
            r.date.isSmallerOrEqualValue(to),
      )
      ..orderBy([(r) => OrderingTerm.asc(r.date)]);
    return q.get();
  }

  /// Latest known rate row (for account cards and quick conversions).
  Stream<FxRate?> watchLatestRate() {
    final q = select(fxRates)
      ..where((r) => r.deleted.equals(false))
      ..orderBy([(r) => OrderingTerm.desc(r.date)])
      ..limit(1);
    return q.watchSingleOrNull();
  }

  /// Upserts a rate for a date. Manual entries overwrite anything; API
  /// entries never overwrite manual ones; imports never overwrite anything.
  Future<void> upsertRate({
    required DateTime date,
    double? usdUgx,
    double? cadUgx,
    double? usdCad,
    required String source,
    required String Function() newId,
  }) async {
    final day = DateTime.utc(date.year, date.month, date.day);
    final existing = await (select(
      fxRates,
    )..where((r) => r.date.equals(day))).getSingleOrNull();
    final now = DateTime.now().toUtc();
    if (existing == null) {
      await into(fxRates).insert(
        FxRatesCompanion.insert(
          id: newId(),
          date: day,
          usdUgx: Value(usdUgx),
          cadUgx: Value(cadUgx),
          usdCad: Value(usdCad),
          source: Value(source),
          createdAt: now,
          updatedAt: now,
        ),
      );
      return;
    }
    const priority = {FxSource.import: 0, FxSource.api: 1, FxSource.manual: 2};
    if ((priority[source] ?? 0) < (priority[existing.source] ?? 0)) return;
    await (update(fxRates)..where((r) => r.id.equals(existing.id))).write(
      FxRatesCompanion(
        usdUgx: Value(usdUgx ?? existing.usdUgx),
        cadUgx: Value(cadUgx ?? existing.cadUgx),
        usdCad: Value(usdCad ?? existing.usdCad),
        source: Value(source),
        deleted: const Value(false),
        updatedAt: Value(now),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final row = await (select(
      appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) async {
    await into(appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: key, value: value),
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'money.db'));
    return NativeDatabase.createInBackground(file);
  });
}
