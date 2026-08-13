# Money — Supabase backup

Pulls every row out of the Money Supabase project and writes it to a folder
you choose, as JSON and CSV, with a copy of the schema. Nothing else is
needed to run it: Python 3.9+ from a stock macOS install is enough — no pip
install, no Flutter, no Supabase CLI.

## What to keep in the backup folder

Put these four files together in one directory, anywhere you like:

```
~/money-backup/
  backup_supabase.py     the script
  sync_config.json       Supabase URL + publishable key
  money.json             schema snapshot   (from the app repo's supabase/)
  schema.sql             table definitions (from the app repo's supabase/)
```

Only `backup_supabase.py` and `sync_config.json` are strictly required. The
two schema files make the backup self-describing and are copied into every
run — keep them, they are what lets you rebuild the tables from scratch.

`sync_config.json` is the same file the app uses. Copy it from the app repo's
`config/sync_config.json`, or write it by hand:

```json
{
  "SUPABASE_URL": "https://YOUR-PROJECT.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_..."
}
```

This file holds no secret worth guarding — the publishable key is designed to
ship inside client apps, and row-level security is what actually protects the
data. **Your account password is a different matter and is never stored
here.**

## Running it

```bash
python3 ~/money-backup/backup_supabase.py --out ~/Backups/money
```

It asks for your Supabase email and password, then prints a line per table:

```
  ledgers              1 rows  [ok]
  accounts             8 rows  [ok]
  categories          24 rows  [ok]
  transactions      3187 rows  [ok]
  fx_rates          7505 rows  [ok]

Backup complete: /Users/you/Backups/money/money-backup-20260813-064154
```

To skip the prompts, set the credentials in the environment instead:

```bash
SUPABASE_EMAIL=you@example.com SUPABASE_PASSWORD='...' \
  python3 ~/money-backup/backup_supabase.py --out ~/Backups/money
```

Mind that a password typed on a command line lands in your shell history.
Prefer the prompt for manual runs, and the environment only for scheduled
ones.

### Options

| Flag | Meaning |
| --- | --- |
| `--out` | **Required.** Where backups go; a timestamped subfolder is created inside. |
| `--email` | Account email, or set `SUPABASE_EMAIL`. |
| `--config` | Path to `sync_config.json`, if not beside the script. |
| `--schema-dir` | Folder holding `money.json` / `schema.sql`, if not beside the script. |

`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` in the environment override the
config file entirely, so no file is needed if you would rather set those.

## What you get

```
~/Backups/money/
  latest -> money-backup-20260813-064154
  money-backup-20260813-064154/
    data/
      ledgers.json      ledgers.csv
      accounts.json     accounts.csv
      categories.json   categories.csv
      transactions.json transactions.csv
      fx_rates.json     fx_rates.csv
    schema/
      money.json
      schema.sql
    manifest.json
```

Every run creates a new timestamped folder; nothing is ever overwritten.
`latest` is a symlink to the most recent **successful** run.

- **JSON** is the authoritative copy — exact types, nulls preserved.
- **CSV** is for reading in a spreadsheet. Booleans are written `true`/`false`
  and columns follow `money.json`'s order.
- **`manifest.json`** records the row counts and a `complete` flag.

Soft-deleted rows are included. The app never hard-deletes — it keeps
tombstones so sync can propagate deletions — and the backup preserves them, so
restoring will not resurrect anything you deleted.

## How you know a backup is good

Before downloading each table the script asks Supabase for an exact row count,
then compares it against what it actually received. A short download is
treated as a failure, not a backup:

- it exits non-zero and prints which tables disagreed,
- `manifest.json` records `"complete": false`,
- the `latest` symlink is **not** moved to the bad run.

The failed folder is kept so you can look at it. If a run reports `complete`,
every row the server had is on disk.

The other reason to trust it: the script pages through tables by `id` rather
than by offset. If your phone syncs in the background halfway through a
backup, offsets would shift under it and rows would be silently skipped; an
id cursor cannot skip.

## Restoring

**Into the app.** Create the tables in a fresh Supabase project by running
`schema.sql` in the SQL Editor — it defines the tables, the RLS policies, and
the `server_updated_at` trigger. Then load the data from the JSON files, most
easily with the Table Editor's CSV import, in this order: `ledgers`,
`accounts`, `categories`, `transactions`, `fx_rates`. Point the app at the new
project by updating `config/sync_config.json`.

**Just reading it.** The CSVs open in any spreadsheet. `transactions.csv` is
the one you want; `account_id` and `category_id` join to the other files.

## Scheduling it

Weekly, via `crontab -e`:

```
0 9 * * 1 cd ~/money-backup && SUPABASE_EMAIL=you@example.com SUPABASE_PASSWORD='...' /usr/bin/python3 backup_supabase.py --out ~/Backups/money >> ~/Backups/money/backup.log 2>&1
```

Check the log occasionally — a backup that has been failing quietly for a
month is worse than no backup, because you think you have one. Grep it for
`MISMATCH` or `failed`.

## What this does not cover

This is a complete backup of **your data**. It is not a restorable Postgres
dump — it does not capture auth users, database roles, or grants.
`schema.sql` recreates the tables, policies and trigger by hand, so recovery
is realistic, but it is a manual rebuild rather than a one-command restore.

For a true dump, use Postgres' own tooling with the connection string from the
Supabase dashboard (Project Settings → Database). This needs the **database**
password, which is not the same as your account password:

```bash
pg_dump "$MONEY_DB_URL" --clean --if-exists --no-owner --no-privileges -f money-dump.sql
```

and to restore:

```bash
psql "$NEW_DB_URL" -f money-dump.sql
```

`pg_dump` must be version 15 or newer or Supabase will refuse it with a server
version mismatch. On macOS: `brew install libpq`, then use
`/opt/homebrew/opt/libpq/bin/pg_dump`.

## A third copy, for free

The app's own **Settings → Export** writes the same data from the device's
local SQLite. That copy does not depend on Supabase being reachable, or on
this script, or on your account still existing. Worth doing occasionally — if
the concern is losing access, an export sitting in your Documents folder is
the one backup nothing can take away from you.
