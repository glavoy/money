# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Money is a Flutter money tracker running on Android, Windows, and macOS from
one codebase. It's offline-first (local SQLite via drift) with optional
two-way Supabase sync between devices.

## Commands

```sh
flutter pub get                    # install dependencies
dart run build_runner build        # regenerate lib/data/database.g.dart after editing lib/data/database.dart
flutter analyze                    # static analysis (flutter_lints)
dart format .                      # format before committing
flutter test                       # run all unit/widget tests
flutter test test/database_test.dart   # run a single test file
flutter run -d windows              # run locally (swap device id for android/macos)
flutter build apk|windows|macos     # release builds
```

Golden/preview tests are skipped by default (see `dart_test.yaml`). To
regenerate them: `flutter test test/preview_test.dart --update-goldens --run-skipped`.

No CI config exists in this repo — `flutter analyze` and `flutter test` are
the checks to run before considering work done.

## Architecture

### Layers

- `lib/data/` — drift database (`database.dart`), schema tables, and seed
  data (`seed.dart`). `database.g.dart` is generated; never hand-edit it —
  run `dart run build_runner build` after changing any `Table` class or
  `@DriftDatabase` annotation.
- `lib/shared/` — cross-feature code: riverpod providers (`providers.dart`),
  currency/FX conversion (`currency.dart`), shared widgets.
- `lib/sync/` — Supabase sync engine (`sync_service.dart`), FX rate fetching
  from open.er-api.com (`fx_fetcher.dart`), and sync config loading.
- `lib/features/<feature>/` — one folder per screen: `quick_add`,
  `transactions`, `accounts`, `reports`, `settings`, `import`, `export`.
  Keep feature-specific UI inside its folder; promote logic to `shared/`
  only when a second feature needs it.

### Data model (`lib/data/database.dart`)

Tables: `Ledgers`, `Accounts`, `Categories`, `Transactions`, `FxRates`,
`AppSettings` (key/value settings + sync bookkeeping).

- Every syncable row has `createdAt`, `updatedAt`, and a soft-delete
  `deleted` flag — rows are never hard-deleted so sync can propagate
  tombstones. Use the `softDelete*` / `upsert*` helper methods on
  `AppDatabase` rather than raw `update`/`delete` calls, so `updatedAt` is
  bumped correctly.
- **Ledgers** partition accounts/categories/transactions (e.g. "Personal"
  vs. other books). Most queries take a `ledgerId` and most UI reads the
  currently selected ledger from `selectedLedgerProvider`.
- **Account balances** are never stored — `watchBalances` computes them via
  SQL from `openingBalance` + summed transactions (including transfers
  in/out) each time.
- **Transactions** cover expense/income/transfer via `TxKind`. Transfers use
  `toAccountId`/`toAmount` (the destination amount, since transfers can
  cross currencies); `categoryId` is null for transfers.
- **FxRates** store `usdUgx`/`cadUgx`/`usdCad` per calendar day (UTC,
  midnight-truncated), with a `source` priority: `import` < `api` <
  `manual`. `upsertRate` enforces that priority — never overwrite a manual
  rate with a fetched one. All FX conversion in `lib/shared/currency.dart`
  routes through UGX as the pivot currency.

### Sync (`lib/sync/sync_service.dart`)

- Two-way, last-write-wins per row, keyed on `updatedAt`. Each of the five
  synced tables (ledgers, accounts, categories, transactions, fx_rates) is
  synced independently: pull remote rows updated since the last sync
  (with a 10-minute overlap window to avoid boundary misses), apply them
  locally if newer, then push local rows updated since that same point.
  `AppSettings` is local-only and never synced.
- Sync only runs when signed in to Supabase (`isSignedIn`); it's a no-op
  otherwise. It runs silently (swallowing errors) on app start, on resume,
  and on a 5-minute timer — see `_HomeShellState` in `lib/main.dart`. If a
  sync is already running when another is requested, it's coalesced into a
  rerun after the current one finishes, rather than run concurrently.
  Manual sync from Settings uses `sync()`, which surfaces errors via
  `SyncResult`.
- `config/sync_config.json` (gitignored; see `config/sync_config.example.json`)
  holds the Supabase URL and publishable key. Without it, sync features are
  simply inert — don't assume it's present when writing tests.
- Seed accounts get special handling in `isUntouchedSeedAccount`: an
  unmodified seed account can be overwritten by a remote row even if the
  remote's `updatedAt` is older, since both devices independently created
  the same seed data at install time.
- `supabase/schema.sql` defines the remote tables (snake_case columns
  mirroring the drift camelCase ones) and is run once manually in the
  Supabase SQL editor. When adding or changing columns on a synced table in
  `lib/data/database.dart`, update `supabase/schema.sql` to match — there is
  no migration tooling connecting the two.

### State management

Riverpod (`flutter_riverpod`), providers centralized in
`lib/shared/providers.dart`. `databaseProvider` is a placeholder overridden
in `main()` with the opened `AppDatabase` — tests must override it too, not
rely on the default. Most list/detail data flows through `StreamProvider`s
backed by drift's reactive `watch*` queries, so UI updates automatically on
DB writes without manual invalidation. Simple persisted preferences (theme,
display currency, last-used account, selected ledger) use `Notifier`s that
read/write through `AppDatabase.getSetting`/`setSetting`.

### Import/export

`lib/features/import/csv_import.dart` and `lib/features/export/csv_export.dart`
handle CSV round-tripping of transactions. `tools/import_xlsx.py` is a
standalone (non-Flutter) helper for converting spreadsheet exports to the
CSV shape the app expects — run it manually outside the Flutter toolchain.

## Conventions

- Two-space indentation, `lower_snake_case.dart` filenames, `UpperCamelCase`
  classes/widgets, `lowerCamelCase` members — standard Dart/`flutter_lints`
  defaults (see `analysis_options.yaml`).
- Add or update tests when changing import logic, database behavior, sync
  behavior, reports, or primary user flows (`test/` mirrors these:
  `csv_import_test.dart`, `database_test.dart`, `fx_fetcher_test.dart`,
  `quick_add_flow_test.dart`, `report_test.dart`, etc.). Tests should not
  require live Supabase credentials or network access.
- Never commit `config/sync_config.json`, build output, or personal
  spreadsheet files.
