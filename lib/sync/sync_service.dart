import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    as riverpod
    show Provider;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/database.dart';
import '../data/seed.dart';
import '../shared/providers.dart';
import 'sync_config.dart';

/// Settings keys used for sync configuration.
class SyncKeys {
  static const lastSyncPrefix = 'last_sync_'; // + table name
}

bool _supabaseInitialized = false;

/// Called from main(); initializes Supabase when the user has configured it.
Future<void> initSupabaseIfConfigured() async {
  try {
    await initSupabaseNow();
  } catch (e) {
    debugPrint('Supabase init failed: $e');
  }
}

/// Initializes Supabase from the local config/sync_config.json asset.
Future<void> initSupabaseNow() async {
  if (_supabaseInitialized) return;
  final config = await SyncConfig.load();
  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabasePublishableKey,
  );
  _supabaseInitialized = true;
}

bool get supabaseReady => _supabaseInitialized;

final syncServiceProvider = riverpod.Provider<SyncService>((ref) {
  return SyncService(ref.watch(databaseProvider));
});

class SyncResult {
  SyncResult({
    required this.pushed,
    required this.pulled,
    this.tables = const [],
    this.error,
  });
  final int pushed;
  final int pulled;
  final List<SyncTableResult> tables;
  final String? error;

  bool get ok => error == null;
}

class SyncTableResult {
  const SyncTableResult({
    required this.name,
    required this.pushed,
    required this.pulled,
  });

  final String name;
  final int pushed;
  final int pulled;
}

class SyncService {
  SyncService(this.db);

  final AppDatabase db;
  bool _running = false;
  bool _rerunAfterCurrent = false;

  bool get isSignedIn =>
      _supabaseInitialized &&
      Supabase.instance.client.auth.currentSession != null;

  /// Background sync that never throws (used on app start/resume).
  Future<void> syncSilently() async {
    if (!isSignedIn) {
      return;
    }
    if (_running) {
      _rerunAfterCurrent = true;
      return;
    }
    try {
      await sync();
    } catch (e) {
      debugPrint('Background sync failed: $e');
    }
  }

  /// Two-way sync of all tables. Last write wins on updated_at.
  Future<SyncResult> sync() async {
    if (!isSignedIn) {
      return SyncResult(
        pushed: 0,
        pulled: 0,
        error: 'Not signed in to Supabase',
      );
    }
    if (_running) {
      return SyncResult(pushed: 0, pulled: 0, error: 'Sync already running');
    }
    _running = true;
    try {
      var pushed = 0, pulled = 0;
      final tableResults = <SyncTableResult>[];
      final client = Supabase.instance.client;
      // Capture the moment sync starts; anything written after this will be
      // picked up next time.
      final syncStart = DateTime.now().toUtc();

      for (final table in _tables) {
        var tablePushed = 0, tablePulled = 0;
        final lastSyncRaw = await db.getSetting(
          '${SyncKeys.lastSyncPrefix}${table.remote}',
        );
        final lastSync = lastSyncRaw == null
            ? DateTime.utc(1970)
            : DateTime.parse(lastSyncRaw).toUtc();

        // Pull all remote rows in pages. This repairs earlier partial pulls
        // where a cursor may have advanced after Supabase returned one page.
        final remoteRows = await _fetchAllRemoteRows(client, table.remote);
        for (final row in remoteRows) {
          if (await table.applyRemote(db, row)) {
            pulled++;
            tablePulled++;
          }
        }

        // Push local changes (including rows just pulled — harmless upsert).
        final localRows = await table.localChangedSince(db, lastSync);
        if (localRows.isNotEmpty) {
          await client.from(table.remote).upsert(localRows);
          pushed += localRows.length;
          tablePushed += localRows.length;
        }

        await db.setSetting(
          '${SyncKeys.lastSyncPrefix}${table.remote}',
          syncStart.toIso8601String(),
        );
        tableResults.add(
          SyncTableResult(
            name: table.remote,
            pushed: tablePushed,
            pulled: tablePulled,
          ),
        );
      }
      return SyncResult(pushed: pushed, pulled: pulled, tables: tableResults);
    } on Object catch (e) {
      return SyncResult(pushed: 0, pulled: 0, error: e.toString());
    } finally {
      _running = false;
      if (_rerunAfterCurrent) {
        _rerunAfterCurrent = false;
        Future<void>.microtask(syncSilently);
      }
    }
  }
}

Future<List<Map<String, dynamic>>> _fetchAllRemoteRows(
  SupabaseClient client,
  String table,
) async {
  const pageSize = 1000;
  final allRows = <Map<String, dynamic>>[];

  for (var from = 0; ; from += pageSize) {
    final page = await client
        .from(table)
        .select()
        .order('updated_at')
        .range(from, from + pageSize - 1);
    allRows.addAll([for (final row in page) Map<String, dynamic>.from(row)]);

    if (page.length < pageSize) {
      return allRows;
    }
  }
}

String _iso(DateTime d) => d.toUtc().toIso8601String();
DateTime _date(dynamic v) => DateTime.parse(v as String).toUtc();
double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

class _TableSync {
  const _TableSync({
    required this.remote,
    required this.localChangedSince,
    required this.applyRemote,
  });

  final String remote;
  final Future<List<Map<String, dynamic>>> Function(AppDatabase, DateTime)
  localChangedSince;

  /// Returns true when the remote row replaced/created a local row.
  final Future<bool> Function(AppDatabase, Map<String, dynamic>) applyRemote;
}

final _tables = <_TableSync>[
  _TableSync(
    remote: 'ledgers',
    localChangedSince: (db, since) async {
      final rows = await (db.select(
        db.ledgers,
      )..where((t) => t.updatedAt.isBiggerThanValue(since))).get();
      return [
        for (final r in rows)
          {
            'id': r.id,
            'name': r.name,
            'archived': r.archived,
            'sort_order': r.sortOrder,
            'created_at': _iso(r.createdAt),
            'updated_at': _iso(r.updatedAt),
            'deleted': r.deleted,
          },
      ];
    },
    applyRemote: (db, row) async {
      final remoteUpdated = _date(row['updated_at']);
      final local = await (db.select(
        db.ledgers,
      )..where((t) => t.id.equals(row['id'] as String))).getSingleOrNull();
      if (local != null && !remoteUpdated.isAfter(local.updatedAt)) {
        return false;
      }
      await db
          .into(db.ledgers)
          .insertOnConflictUpdate(
            LedgersCompanion(
              id: Value(row['id'] as String),
              name: Value(row['name'] as String),
              archived: Value(row['archived'] as bool? ?? false),
              sortOrder: Value((row['sort_order'] as num?)?.toInt() ?? 0),
              createdAt: Value(_date(row['created_at'])),
              updatedAt: Value(remoteUpdated),
              deleted: Value(row['deleted'] as bool? ?? false),
            ),
          );
      return true;
    },
  ),
  _TableSync(
    remote: 'accounts',
    localChangedSince: (db, since) async {
      final rows = await (db.select(
        db.accounts,
      )..where((t) => t.updatedAt.isBiggerThanValue(since))).get();
      return [
        for (final r in rows)
          {
            'id': r.id,
            'ledger_id': r.ledgerId,
            'name': r.name,
            'type': r.type,
            'currency': r.currency,
            'opening_balance': r.openingBalance,
            'opening_date': r.openingDate == null ? null : _iso(r.openingDate!),
            'archived': r.archived,
            'sort_order': r.sortOrder,
            'created_at': _iso(r.createdAt),
            'updated_at': _iso(r.updatedAt),
            'deleted': r.deleted,
          },
      ];
    },
    applyRemote: (db, row) async {
      final remoteUpdated = _date(row['updated_at']);
      final local = await (db.select(
        db.accounts,
      )..where((t) => t.id.equals(row['id'] as String))).getSingleOrNull();
      if (local != null &&
          !remoteUpdated.isAfter(local.updatedAt) &&
          !isUntouchedSeedAccount(local)) {
        return false;
      }
      await db
          .into(db.accounts)
          .insertOnConflictUpdate(
            AccountsCompanion(
              id: Value(row['id'] as String),
              ledgerId: Value(row['ledger_id'] as String? ?? personalLedgerId),
              name: Value(row['name'] as String),
              type: Value(row['type'] as String),
              currency: Value(row['currency'] as String),
              openingBalance: Value(_num(row['opening_balance']) ?? 0),
              openingDate: Value(
                row['opening_date'] == null ? null : _date(row['opening_date']),
              ),
              archived: Value(row['archived'] as bool? ?? false),
              sortOrder: Value((row['sort_order'] as num?)?.toInt() ?? 0),
              createdAt: Value(_date(row['created_at'])),
              updatedAt: Value(remoteUpdated),
              deleted: Value(row['deleted'] as bool? ?? false),
            ),
          );
      return true;
    },
  ),
  _TableSync(
    remote: 'categories',
    localChangedSince: (db, since) async {
      final rows = await (db.select(
        db.categories,
      )..where((t) => t.updatedAt.isBiggerThanValue(since))).get();
      return [
        for (final r in rows)
          {
            'id': r.id,
            'ledger_id': r.ledgerId,
            'name': r.name,
            'kind': r.kind,
            'sort_order': r.sortOrder,
            'color': r.color,
            'archived': r.archived,
            'created_at': _iso(r.createdAt),
            'updated_at': _iso(r.updatedAt),
            'deleted': r.deleted,
          },
      ];
    },
    applyRemote: (db, row) async {
      final remoteUpdated = _date(row['updated_at']);
      final local = await (db.select(
        db.categories,
      )..where((t) => t.id.equals(row['id'] as String))).getSingleOrNull();
      if (local != null && !remoteUpdated.isAfter(local.updatedAt)) {
        return false;
      }
      await db
          .into(db.categories)
          .insertOnConflictUpdate(
            CategoriesCompanion(
              id: Value(row['id'] as String),
              ledgerId: Value(row['ledger_id'] as String? ?? personalLedgerId),
              name: Value(row['name'] as String),
              kind: Value(row['kind'] as String),
              sortOrder: Value((row['sort_order'] as num?)?.toInt() ?? 0),
              color: Value((row['color'] as num?)?.toInt()),
              archived: Value(row['archived'] as bool? ?? false),
              createdAt: Value(_date(row['created_at'])),
              updatedAt: Value(remoteUpdated),
              deleted: Value(row['deleted'] as bool? ?? false),
            ),
          );
      return true;
    },
  ),
  _TableSync(
    remote: 'transactions',
    localChangedSince: (db, since) async {
      final rows = await (db.select(
        db.transactions,
      )..where((t) => t.updatedAt.isBiggerThanValue(since))).get();
      return [
        for (final r in rows)
          {
            'id': r.id,
            'ledger_id': r.ledgerId,
            'date': _iso(r.date),
            'kind': r.kind,
            'amount': r.amount,
            'account_id': r.accountId,
            'category_id': r.categoryId,
            'to_account_id': r.toAccountId,
            'to_amount': r.toAmount,
            'note': r.note,
            'created_at': _iso(r.createdAt),
            'updated_at': _iso(r.updatedAt),
            'deleted': r.deleted,
          },
      ];
    },
    applyRemote: (db, row) async {
      final remoteUpdated = _date(row['updated_at']);
      final local = await (db.select(
        db.transactions,
      )..where((t) => t.id.equals(row['id'] as String))).getSingleOrNull();
      if (local != null && !remoteUpdated.isAfter(local.updatedAt)) {
        return false;
      }
      await db
          .into(db.transactions)
          .insertOnConflictUpdate(
            TransactionsCompanion(
              id: Value(row['id'] as String),
              ledgerId: Value(row['ledger_id'] as String? ?? personalLedgerId),
              date: Value(_date(row['date'])),
              kind: Value(row['kind'] as String),
              amount: Value(_num(row['amount'])!),
              accountId: Value(row['account_id'] as String),
              categoryId: Value(row['category_id'] as String?),
              toAccountId: Value(row['to_account_id'] as String?),
              toAmount: Value(_num(row['to_amount'])),
              note: Value(row['note'] as String?),
              createdAt: Value(_date(row['created_at'])),
              updatedAt: Value(remoteUpdated),
              deleted: Value(row['deleted'] as bool? ?? false),
            ),
          );
      return true;
    },
  ),
  _TableSync(
    remote: 'fx_rates',
    localChangedSince: (db, since) async {
      final rows = await (db.select(
        db.fxRates,
      )..where((t) => t.updatedAt.isBiggerThanValue(since))).get();
      return [
        for (final r in rows)
          {
            'id': r.id,
            'date': _iso(r.date),
            'usd_ugx': r.usdUgx,
            'cad_ugx': r.cadUgx,
            'usd_cad': r.usdCad,
            'source': r.source,
            'created_at': _iso(r.createdAt),
            'updated_at': _iso(r.updatedAt),
            'deleted': r.deleted,
          },
      ];
    },
    applyRemote: (db, row) async {
      final remoteUpdated = _date(row['updated_at']);
      final local = await (db.select(
        db.fxRates,
      )..where((t) => t.id.equals(row['id'] as String))).getSingleOrNull();
      if (local != null && !remoteUpdated.isAfter(local.updatedAt)) {
        return false;
      }
      // A row for the same date may exist locally under a different id
      // (e.g. both devices fetched the same day's rate). Keep the local id.
      final sameDate = await (db.select(
        db.fxRates,
      )..where((t) => t.date.equals(_date(row['date'])))).getSingleOrNull();
      final id = sameDate?.id ?? row['id'] as String;
      await db
          .into(db.fxRates)
          .insertOnConflictUpdate(
            FxRatesCompanion(
              id: Value(id),
              date: Value(_date(row['date'])),
              usdUgx: Value(_num(row['usd_ugx'])),
              cadUgx: Value(_num(row['cad_ugx'])),
              usdCad: Value(_num(row['usd_cad'])),
              source: Value(row['source'] as String? ?? FxSource.api),
              createdAt: Value(_date(row['created_at'])),
              updatedAt: Value(remoteUpdated),
              deleted: Value(row['deleted'] as bool? ?? false),
            ),
          );
      return true;
    },
  ),
];

@visibleForTesting
Future<List<Map<String, dynamic>>> exportChangedRowsForTest(
  AppDatabase db,
  String table,
  DateTime since,
) {
  return _tables
      .singleWhere((syncTable) => syncTable.remote == table)
      .localChangedSince(db, since);
}

@visibleForTesting
Future<bool> applyRemoteRowForTest(
  AppDatabase db,
  String table,
  Map<String, dynamic> row,
) {
  return _tables
      .singleWhere((syncTable) => syncTable.remote == table)
      .applyRemote(db, row);
}

@visibleForTesting
bool isUntouchedSeedAccount(Account account) {
  SeedAccount? seed;
  var seedIndex = -1;
  for (var i = 0; i < seedAccounts.length; i++) {
    if (seedAccounts[i].id == account.id) {
      seed = seedAccounts[i];
      seedIndex = i;
      break;
    }
  }
  if (seed == null) {
    return false;
  }

  return account.name == seed.name &&
      account.type == seed.type &&
      account.currency == seed.currency &&
      account.openingBalance == 0 &&
      account.openingDate == null &&
      account.archived == (seed.id == historyAccountId) &&
      account.sortOrder == seedIndex &&
      !account.deleted &&
      account.createdAt.isAtSameMomentAs(account.updatedAt);
}
