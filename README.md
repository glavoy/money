# Money

A Flutter money tracker.
Runs on Android, Windows, and macOS from one codebase. Offline-first (local
SQLite via drift) with optional Supabase sync between devices.

## Features

- **Quick Add** — expense / income / transfer entry with category grid and
  account chips; remembers your last account; shows the day's entries and total.
- **History** — all transactions grouped by day, filterable by date range,
  account, and category; tap to edit, swipe left to delete.
- **Accounts** — live balances for Cash, Banks, Mobile Money, etc.
- **Reports** — month / quarter / year
- **Exchange rates** — fetched automatically from open.er-api.com, or entered manually (manual always wins).
- **Sync** — optional two-way Supabase sync (last write wins).

## Building

Requires Flutter 3.44+.

```sh
flutter pub get
dart run build_runner build        # regenerates lib/data/database.g.dart after schema changes
flutter test
flutter build apk                  # Android
flutter build windows              # Windows
flutter build macos                # macOS (on a Mac)
```

For development: `flutter run -d windows` (or an Android device).



## Setting up sync (optional)

1. Create a free project at supabase.com.
2. Dashboard → SQL Editor → run the contents of `supabase/schema.sql`.
3. Dashboard → Authentication → Users → **Add user** (your email + a password,
   with "Auto confirm user" enabled).
4. Copy `config/sync_config.example.json` to `config/sync_config.json`, then
   fill in the project URL and publishable/anon key from Dashboard → Settings →
   API keys. `config/sync_config.json` is gitignored.
5. Run the app normally:

```sh
flutter run -d windows
# or
flutter run -d android
```

6. In the app on each device: **Settings → Sync** → sign in with the user from
   step 3, then **Sync now**.

Sync also runs automatically in the background each time the app starts.
Conflicts resolve as last-write-wins per row; deletes are soft and propagate.

## Project layout

```
lib/
  data/       drift database, schema, seed accounts/categories
  features/   one folder per screen (quick_add, transactions, accounts,
              reports, settings, import)
  shared/     currency + FX conversion, riverpod providers
  sync/       Supabase sync service, FX rate fetcher
supabase/schema.sql   one-time Supabase setup
tools/import_xlsx.py  spreadsheet → CSV converter
test/                 unit + widget tests
```
