import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    as riverpod
    show Provider, StreamProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/database.dart';
import '../data/seed.dart';
import '../shared/providers.dart';
import 'sync_config.dart';

class SyncKeys {
  static const lastSyncPrefix = 'last_sync_';
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
  final service = SyncService(ref.watch(databaseProvider));
  ref.onDispose(service.dispose);
  return service;
});

final syncStateProvider = riverpod.StreamProvider<int>((ref) {
  return ref.watch(syncServiceProvider).changes;
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

  static const _incrementalOverlap = Duration(minutes: 10);

  final AppDatabase db;
  bool _rerunAfterCurrent = false;
  Future<SyncResult>? _currentSync;
  SyncResult? _lastResult;
  var _changeVersion = 0;
  final _changes = StreamController<int>.broadcast();

  bool get isRunning => _currentSync != null;
  SyncResult? get lastResult => _lastResult;
  Stream<int> get changes => _changes.stream;

  void dispose() {
    _changes.close();
  }

  void _emitChanged() {
    if (!_changes.isClosed) {
      _changes.add(++_changeVersion);
    }
  }

  bool get isSignedIn =>
      _supabaseInitialized &&
      Supabase.instance.client.auth.currentSession != null;

  /// Background sync that never throws (used on app start/resume).
  Future<void> syncSilently() async {
    if (!isSignedIn) {
      return;
    }
    if (isRunning) {
      _rerunAfterCurrent = true;
      return;
    }
    Future<void>.microtask(sync);
  }

  /// Two-way sync of all tables. Last write wins on updated_at.
  ///
  /// Sync is incremental with a small overlap window to avoid missing rows near
  /// the previous sync boundary.
  Future<SyncResult> sync() async {
    if (!isSignedIn) {
      return SyncResult(
        pushed: 0,
        pulled: 0,
        error: 'Not signed in to Supabase',
      );
    }
    if (_currentSync != null) {
      return _currentSync!;
    }

    _currentSync = _runSync();
    _emitChanged();
    try {
      final result = await _currentSync!;
      _lastResult = result;
      return result;
    } finally {
      _currentSync = null;
      _emitChanged();
      if (_rerunAfterCurrent) {
        _rerunAfterCurrent = false;
        Future<void>.microtask(syncSilently);
      }
    }
  }

  Future<SyncResult> _runSync() async {
    try {
      var pushed = 0, pulled = 0;
      final tableResults = <SyncTableResult>[];
      final client = Supabase.instance.client;
      final syncStart = DateTime.now().toUtc();

      for (final table in _tables) {
        var tablePushed = 0, tablePulled = 0;
        final lastSyncRaw = await db.getSetting(
          '${SyncKeys.lastSyncPrefix}${table.remote}',
        );
        final since = lastSyncRaw == null
            ? DateTime.utc(1970)
            : DateTime.parse(lastSyncRaw).toUtc().subtract(_incrementalOverlap);

        final remoteRows = await _fetchRemoteRowsSince(
          client,
          table.remote,
          since,
        );
        for (final row in remoteRows) {
          if (await table.applyRemote(db, row)) {
            pulled++;
            tablePulled++;
          }
        }

        // Push local rows after remote rows are applied. If remote had the
        // newer version of a row, local now has that newer version too.
        final localRows = await table.localRowsSince(db, since);
        if (localRows.isNotEmpty) {
          await client.from(table.remote).upsert(localRows);
          pushed += localRows.length;
          tablePushed += localRows.length;
        }
        tableResults.add(
          SyncTableResult(
            name: table.remote,
            pushed: tablePushed,
            pulled: tablePulled,
          ),
        );
        await db.setSetting(
          '${SyncKeys.lastSyncPrefix}${table.remote}',
          syncStart.toIso8601String(),
        );
      }
      return SyncResult(pushed: pushed, pulled: pulled, tables: tableResults);
    } on Object catch (e) {
      return SyncResult(pushed: 0, pulled: 0, error: e.toString());
    }
  }
}

Future<List<Map<String, dynamic>>> _fetchRemoteRowsSince(
  SupabaseClient client,
  String table,
  DateTime since,
) async {
  const pageSize = 1000;
  final allRows = <Map<String, dynamic>>[];

  for (var from = 0; ; from += pageSize) {
    final page = await client
        .from(table)
        .select()
        .gte('updated_at', _iso(since))
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
    required this.localRowsSince,
    required this.applyRemote,
  });

  final String remote;
  final Future<List<Map<String, dynamic>>> Function(AppDatabase, DateTime)
  localRowsSince;

  /// Returns true when the remote row replaced/created a local row.
  final Future<bool> Function(AppDatabase, Map<String, dynamic>) applyRemote;
}

final _tables = <_TableSync>[
  _TableSync(
    remote: 'ledgers',
    localRowsSince: (db, since) async {
      final rows = await (db.select(
        db.ledgers,
      )..where((t) => t.updatedAt.isBiggerOrEqualValue(since))).get();
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
      if (local != null && local.updatedAt.isAfter(remoteUpdated)) {
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
    localRowsSince: (db, since) async {
      final rows = await (db.select(
        db.accounts,
      )..where((t) => t.updatedAt.isBiggerOrEqualValue(since))).get();
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
          local.updatedAt.isAfter(remoteUpdated) &&
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
    localRowsSince: (db, since) async {
      final rows = await (db.select(
        db.categories,
      )..where((t) => t.updatedAt.isBiggerOrEqualValue(since))).get();
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
      if (local != null && local.updatedAt.isAfter(remoteUpdated)) {
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
    localRowsSince: (db, since) async {
      final rows = await (db.select(
        db.transactions,
      )..where((t) => t.updatedAt.isBiggerOrEqualValue(since))).get();
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
      if (local != null && local.updatedAt.isAfter(remoteUpdated)) {
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
    localRowsSince: (db, since) async {
      final rows = await (db.select(
        db.fxRates,
      )..where((t) => t.updatedAt.isBiggerOrEqualValue(since))).get();
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
      if (local != null && local.updatedAt.isAfter(remoteUpdated)) {
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
Future<List<Map<String, dynamic>>> exportLocalRowsForTest(
  AppDatabase db,
  String table,
) {
  return _tables
      .singleWhere((syncTable) => syncTable.remote == table)
      .localRowsSince(db, DateTime.utc(1970));
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
