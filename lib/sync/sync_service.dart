import 'dart:async';
import 'dart:math' as math;

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
  /// Push bookmark: the point up to which this device's local changes have
  /// been pushed. Compared against the client-stamped updated_at, which is
  /// safe here because a device always knows definitively whether it has
  /// pushed its own row — there's no cross-device timing gap on this side.
  static const lastSyncPrefix = 'last_sync_';

  /// Pull bookmark: keyset cursor for how far remote rows have been
  /// fetched, stored as `<server_updated_at ISO>|<id>`. Compared against
  /// server_updated_at (stamped by Postgres on arrival, never by the
  /// client), so a device catching up after any delay — however long — is
  /// guaranteed to still find rows that arrived after its last pull. A
  /// separate cursor from the push bookmark above because the two compare
  /// against different clocks (server vs. client).
  ///
  /// This is an exact keyset cursor, not a time-window overlap: "give me
  /// rows strictly after this (timestamp, id) pair," with the id breaking
  /// ties on equal timestamps. A time-based overlap was tried first and
  /// backfired badly — a bulk backfill (e.g. adding this column to existing
  /// rows) stamps many rows within the same few seconds, and any fixed
  /// overlap wide enough to cover that cluster re-matches the entire
  /// cluster on every subsequent sync forever, since the bookmark can never
  /// advance past it. A keyset cursor has no such window to get wrong.
  static const lastPullPrefix = 'last_pull_';
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

  /// Overlap for the push cursor. Generous, though push has no cross-device
  /// timing gap to guard against (see [SyncKeys.lastSyncPrefix]) — this only
  /// cushions this device's own clock jitter between runs.
  static const _pushOverlap = Duration(minutes: 10);

  /// Per-request timeout so a dead socket (e.g. Android suspending the app
  /// mid-request) fails the sync instead of leaving it running forever.
  static const requestTimeout = Duration(seconds: 30);

  /// Rows per push request, so a large backlog stays within [requestTimeout]
  /// even on a slow mobile connection.
  static const _pushChunkSize = 500;

  final AppDatabase db;
  bool _rerunAfterCurrent = false;
  Future<SyncResult>? _currentSync;
  SyncResult? _lastResult;
  String? _progress;
  var _changeVersion = 0;
  final _changes = StreamController<int>.broadcast();

  bool get isRunning => _currentSync != null;
  SyncResult? get lastResult => _lastResult;

  /// Short description of what the running sync is doing, for the sync screen.
  String? get progress => _progress;
  Stream<int> get changes => _changes.stream;

  void dispose() {
    _changes.close();
  }

  void _emitChanged() {
    if (!_changes.isClosed) {
      _changes.add(++_changeVersion);
    }
  }

  void _setProgress(String? value) {
    _progress = value;
    _emitChanged();
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
  /// Pull and push each track their own incremental cursor. Pushes compare
  /// against this device's own updated_at (safe — a device always knows
  /// whether it pushed its own row). Pulls compare against server_updated_at,
  /// which Postgres stamps at commit time and the client can't influence, so
  /// a device that's been offline for any length of time is still guaranteed
  /// to find everything it missed on its next sync.
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
      _progress = null;
      _emitChanged();
      if (_rerunAfterCurrent) {
        _rerunAfterCurrent = false;
        Future<void>.microtask(syncSilently);
      }
    }
  }

  Future<SyncResult> _runSync() async {
    var pushed = 0, pulled = 0;
    final tableResults = <SyncTableResult>[];
    final errors = <String>[];
    final client = Supabase.instance.client;
    final syncStart = DateTime.now().toUtc();

    // Each table syncs independently: an error in one still lets the others
    // finish and advance their bookmarks.
    for (final table in _tables) {
      var tablePushed = 0, tablePulled = 0;
      try {
        _setProgress(table.remote);
        final lastPushRaw = await db.getSetting(
          '${SyncKeys.lastSyncPrefix}${table.remote}',
        );
        final pushSince = lastPushRaw == null
            ? DateTime.utc(1970)
            : DateTime.parse(lastPushRaw).toUtc().subtract(_pushOverlap);
        final lastPullRaw = await db.getSetting(
          '${SyncKeys.lastPullPrefix}${table.remote}',
        );
        var cursorTs = DateTime.utc(1970);
        String? cursorId;
        if (lastPullRaw != null) {
          final sep = lastPullRaw.indexOf('|');
          cursorTs = DateTime.parse(lastPullRaw.substring(0, sep)).toUtc();
          cursorId = lastPullRaw.substring(sep + 1);
        }

        // Pull page by page using an exact keyset cursor — "rows strictly
        // after (cursorTs, cursorId)" — rather than a time-window overlap.
        // Checkpointing after each page (not just once at the end) means a
        // first-time catch-up spanning dozens of pages makes forward
        // progress even if Android suspends or kills the app mid-sync.
        // Remember which row versions came from remote so the push below
        // doesn't echo them all back.
        final appliedVersions = <String, String>{};
        var fetched = 0;
        for (;;) {
          var query = client.from(table.remote).select();
          query = cursorId == null
              ? query.gte('server_updated_at', _iso(cursorTs))
              : query.or(
                  'server_updated_at.gt.${_iso(cursorTs)},'
                  'and(server_updated_at.eq.${_iso(cursorTs)},id.gt.$cursorId)',
                );
          final page = await query
              .order('server_updated_at', ascending: true)
              .order('id', ascending: true)
              .limit(_pullPageSize)
              .timeout(requestTimeout);
          final rows = [for (final row in page) Map<String, dynamic>.from(row)];
          fetched += rows.length;
          if (rows.isNotEmpty) {
            _setProgress('${table.remote}: applying $fetched rows');
            await db.transaction(() async {
              for (final row in rows) {
                final applied = await table.applyRemote(db, row);
                if (applied) {
                  pulled++;
                  tablePulled++;
                  appliedVersions[row['id'] as String] = _iso(
                    _date(row['updated_at']),
                  );
                }
              }
            });
            // Rows are ordered ascending, so the last row of the page is the
            // new cursor position.
            final last = rows.last;
            cursorTs = _date(last['server_updated_at']);
            cursorId = last['id'] as String;
            await db.setSetting(
              '${SyncKeys.lastPullPrefix}${table.remote}',
              '${_iso(cursorTs)}|$cursorId',
            );
          }
          if (rows.length < _pullPageSize) {
            break;
          }
        }

        // Push local rows after remote rows are applied. If remote had the
        // newer version of a row, local now has that newer version too. Rows
        // whose current version was just applied from remote are unchanged
        // there — pushing them back would only burn bandwidth (fatal when
        // catching up on thousands of rows over a mobile connection).
        final localRows = filterAlreadyPushedRows(
          await table.localRowsSince(db, pushSince),
          appliedVersions,
        );
        for (var i = 0; i < localRows.length; i += _pushChunkSize) {
          final end = math.min(i + _pushChunkSize, localRows.length);
          _setProgress('${table.remote}: pushing $end/${localRows.length}');
          await client
              .from(table.remote)
              .upsert(
                localRows.sublist(i, end),
                onConflict: table.pushOnConflict,
              )
              .timeout(requestTimeout);
          pushed += end - i;
          tablePushed += end - i;
        }
        await db.setSetting(
          '${SyncKeys.lastSyncPrefix}${table.remote}',
          syncStart.toIso8601String(),
        );
      } on Object catch (e) {
        errors.add('${table.remote}: $e');
      }
      tableResults.add(
        SyncTableResult(
          name: table.remote,
          pushed: tablePushed,
          pulled: tablePulled,
        ),
      );
    }
    return SyncResult(
      pushed: pushed,
      pulled: pulled,
      tables: tableResults,
      error: errors.isEmpty ? null : errors.join('\n'),
    );
  }
}

const _pullPageSize = 1000;

/// Drops local rows whose exact version was just applied from remote —
/// remote already has them, so pushing them back is pure overhead.
@visibleForTesting
List<Map<String, dynamic>> filterAlreadyPushedRows(
  List<Map<String, dynamic>> localRows,
  Map<String, String> appliedVersions,
) {
  return [
    for (final row in localRows)
      if (appliedVersions[row['id']] != row['updated_at']) row,
  ];
}

String _iso(DateTime d) => d.toUtc().toIso8601String();
DateTime _date(dynamic v) => DateTime.parse(v as String).toUtc();
double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

class _TableSync {
  const _TableSync({
    required this.remote,
    required this.localRowsSince,
    required this.applyRemote,
    this.pushOnConflict,
  });

  final String remote;
  final Future<List<Map<String, dynamic>>> Function(AppDatabase, DateTime)
  localRowsSince;

  /// Returns true when the remote row replaced/created a local row.
  final Future<bool> Function(AppDatabase, Map<String, dynamic>) applyRemote;

  /// Remote column for upsert conflict resolution; null targets the primary
  /// key. fx_rates uses its unique date so two devices that independently
  /// fetched the same day's rate (under different ids) update one remote row
  /// instead of violating the unique constraint.
  final String? pushOnConflict;
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
    pushOnConflict: 'date',
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
      final remoteId = row['id'] as String;
      final local = await (db.select(
        db.fxRates,
      )..where((t) => t.id.equals(remoteId))).getSingleOrNull();
      if (local != null && local.updatedAt.isAfter(remoteUpdated)) {
        return false;
      }
      // A row for the same date may exist locally under a different id
      // (e.g. both devices fetched the same day's rate before syncing).
      final sameDate = await (db.select(
        db.fxRates,
      )..where((t) => t.date.equals(_date(row['date'])))).getSingleOrNull();
      if (sameDate != null && sameDate.id != remoteId) {
        if (sameDate.updatedAt.isAfter(remoteUpdated)) {
          // The local rate is newer; keep it. The push (onConflict: date)
          // overwrites the remote row for this date with it.
          return false;
        }
        // Adopt the remote id: replace the locally-created row so a later
        // push can't insert a second id for a date the remote already has
        // (its unique date constraint would reject the whole chunk). The
        // date's row lives on under the remote id, so no tombstone is lost.
        await (db.delete(
          db.fxRates,
        )..where((t) => t.id.equals(sameDate.id))).go();
      }
      await db
          .into(db.fxRates)
          .insertOnConflictUpdate(
            FxRatesCompanion(
              id: Value(remoteId),
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
