# Expense Tracker

A Flutter expense tracker that replaces the `glavoy20xx.xlsx` spreadsheets.
Runs on Android, Windows, and macOS from one codebase. Offline-first (local
SQLite via drift) with optional Supabase sync between devices.

## Features

- **Quick Add** — expense / income / transfer entry with category grid and
  account chips; remembers your last account; shows the day's entries and total.
- **History** — all transactions grouped by day, filterable by date range,
  account, and category; tap to edit, swipe left to delete.
- **Accounts** — live balances for Cash, Stanbic Bank, USD Bank, MTN Mobile
  Money (×2), Airtel Money, and Visa; per-account ledger with running balance
  (replaces the Balance / MTN / Airtel sheets); transfers and currency
  exchanges (e.g. "Changed $2000 @ 3585") move money between accounts and
  record the real rate.
- **Reports** — month / quarter / year, viewable in UGX, USD, or CAD (converted
  per-transaction with the exchange rate of that day); spending-by-day chart,
  category breakdown, monthly summary table.
- **Exchange rates** — daily UGX/USD/CAD rates back to 2006 (imported), fetched
  automatically from open.er-api.com, or entered manually (manual always wins).
- **Import** — one-time import of ~20 years of spreadsheet history.
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

## Importing the spreadsheet history

1. Generate CSVs from the spreadsheets (requires Python 3 + openpyxl):

   ```sh
   python tools/import_xlsx.py --raw C:/temp/raw_data.xlsx --y2026 C:/temp/glavoy2026.xlsx --out C:/temp/import_csv
   ```

   This writes `transactions.csv` (daily expenses 2006→today + monthly income),
   `fx_rates.csv` (daily rates), and `validation.txt` (monthly totals per
   category for spot-checking against the 'monthly ex' sheet).
   `glavoy2025.xlsx` is not needed — 2025 is already inside `raw_data.xlsx`.

2. Copy the two CSVs to the device, then in the app: **Settings → Import
   data → Choose CSV files**. Re-importing is safe (rows have stable ids and
   overwrite themselves).

3. Historical entries are booked against a hidden **Imported history** account
   so your real accounts start clean. Set each real account's *current* balance
   as its **opening balance** in **Settings → Accounts** (take the numbers from
   the spreadsheet's Balance / mobile-money sheets). From then on, every new
   expense/income/transfer keeps the balances up to date automatically.

## Setting up sync (optional)

1. Create a free project at supabase.com.
2. Dashboard → SQL Editor → run the contents of `supabase/schema.sql`.
3. Dashboard → Authentication → Users → **Add user** (your email + a password,
   with "Auto confirm user" enabled).
4. In the app on each device: **Settings → Sync** → enter the project URL and
   the publishable/anon key (Dashboard → Settings → API keys), sign in with the
   user from step 3, then **Sync now**.

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
