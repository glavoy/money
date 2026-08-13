#!/usr/bin/env python3
"""Back up the Money Supabase project — schema snapshot plus every data row.

Standalone: standard library only, no pip install, no Flutter toolchain.

    python3 tools/backup_supabase.py --out ~/Backups/money

Writes a timestamped folder holding one JSON and one CSV per table, the
schema files from supabase/, and a manifest recording row counts.

Credentials
-----------
Reads SUPABASE_URL and the publishable key from config/sync_config.json (the
same file the app uses). Your account password is never read from a file and
never written to the backup: supply it as SUPABASE_PASSWORD in the
environment, or let the script prompt for it.

Scope
-----
This captures the five synced tables in full, including soft-deleted
tombstone rows, so it is a complete record of your data. It does not produce
a restorable Postgres dump — no auth users, no roles, no grants. For that,
see `pg_dump` in the README section at the bottom of this file.
"""

from __future__ import annotations

import argparse
import csv
import getpass
import json
import os
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

# Searched in order, so the script works both inside the app repo and on its
# own in a backup folder with the config and schema files sitting beside it.
CONFIG_CANDIDATES = [
    SCRIPT_DIR / "sync_config.json",
    REPO_ROOT / "config" / "sync_config.json",
]
SCHEMA_DIR_CANDIDATES = [
    SCRIPT_DIR,
    SCRIPT_DIR / "supabase",
    REPO_ROOT / "supabase",
]
SCHEMA_JSON_NAME = "money.json"
SCHEMA_SQL_NAME = "schema.sql"

# Order matters: ledgers before the rows that reference them, so a human
# reading the backup meets the parents first. Every table is fetched in full.
TABLES = ["ledgers", "accounts", "categories", "transactions", "fx_rates"]

PAGE_SIZE = 1000
TIMEOUT = 60


class BackupError(Exception):
    """Anything that should stop the backup with a readable message."""


def find_config(explicit: str | None) -> Path | None:
    if explicit:
        path = Path(explicit).expanduser()
        if not path.exists():
            raise BackupError(f"No config file at {path}.")
        return path
    return next((p for p in CONFIG_CANDIDATES if p.exists()), None)


def load_config(explicit: str | None) -> tuple[str, str]:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_PUBLISHABLE_KEY")
    if url and key:
        return url.rstrip("/"), key
    path = find_config(explicit)
    if path is None:
        searched = "\n  ".join(str(p) for p in CONFIG_CANDIDATES)
        raise BackupError(
            "Could not find sync_config.json. Looked in:\n  "
            f"{searched}\nPass --config, or set SUPABASE_URL and "
            "SUPABASE_PUBLISHABLE_KEY in the environment."
        )
    data = json.loads(path.read_text())
    try:
        return data["SUPABASE_URL"].rstrip("/"), data["SUPABASE_PUBLISHABLE_KEY"]
    except KeyError as exc:
        raise BackupError(f"{path} is missing {exc}.") from exc


def find_schema_dir(explicit: str | None) -> Path | None:
    """Directory holding money.json / schema.sql, if one can be found."""
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_dir():
            raise BackupError(f"No schema directory at {path}.")
        return path
    return next(
        (p for p in SCHEMA_DIR_CANDIDATES if (p / SCHEMA_JSON_NAME).exists()),
        None,
    )


def request(
    url: str, *, headers: dict[str, str], data: bytes | None = None,
    method: str | None = None,
) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        raise BackupError(f"HTTP {exc.code} from {url}\n{body}") from exc
    except urllib.error.URLError as exc:
        raise BackupError(f"Could not reach {url}: {exc.reason}") from exc


def sign_in(base_url: str, key: str, email: str, password: str) -> str:
    """Exchanges email/password for an access token. Returns the token only."""
    url = f"{base_url}/auth/v1/token?grant_type=password"
    payload = json.dumps({"email": email, "password": password}).encode()
    _, _, body = request(
        url,
        headers={
            "apikey": key,
            "Content-Type": "application/json",
        },
        data=payload,
    )
    token = json.loads(body).get("access_token")
    if not token:
        raise BackupError("Sign-in succeeded but returned no access token.")
    return token


def table_count(base_url: str, headers: dict[str, str], table: str) -> int:
    """Server-side exact count, used to prove the download was complete."""
    url = f"{base_url}/rest/v1/{table}?select=id"
    _, resp_headers, _ = request(
        url,
        headers={**headers, "Prefer": "count=exact", "Range": "0-0"},
    )
    content_range = resp_headers.get("Content-Range", "")
    total = content_range.rsplit("/", 1)[-1]
    if not total.isdigit():
        raise BackupError(f"No usable count for {table} (got {content_range!r}).")
    return int(total)


def fetch_table(base_url: str, headers: dict[str, str], table: str) -> list[dict]:
    """Fetches every row, paging by id.

    Keyset rather than offset: offset paging can skip or repeat rows if
    anything writes mid-backup (a phone syncing in the background is exactly
    that), whereas an id cursor is stable under concurrent inserts.
    """
    rows: list[dict] = []
    cursor: str | None = None
    while True:
        params = {
            "select": "*",
            "order": "id.asc",
            "limit": str(PAGE_SIZE),
        }
        if cursor is not None:
            params["id"] = f"gt.{cursor}"
        url = f"{base_url}/rest/v1/{table}?" + urllib.parse.urlencode(params)
        _, _, body = request(url, headers=headers)
        page = json.loads(body)
        if not page:
            break
        rows.extend(page)
        cursor = page[-1]["id"]
        if len(page) < PAGE_SIZE:
            break
    return rows


def schema_columns(schema_dir: Path | None) -> dict[str, list[str]]:
    """Canonical column order per table, taken from the schema snapshot.

    Deriving CSV headers from the schema rather than from the first row keeps
    every column present even when the rows that happen to come back all have
    a null there.
    """
    if schema_dir is None:
        return {}
    path = schema_dir / SCHEMA_JSON_NAME
    if not path.exists():
        return {}
    doc = json.loads(path.read_text())
    tables = doc[0]["project_schema"]["tables"] if isinstance(doc, list) else []
    return {
        t["table_name"]: [c["column"] for c in t["columns"]] for t in tables
    }


def csv_value(value: object) -> object:
    # Python would render these as True/False; the app's own CSV export uses
    # lowercase, and so does Postgres. Keep the two readable side by side.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return value


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: csv_value(row.get(c)) for c in columns})


def run_backup(
    out_root: Path,
    email: str,
    password: str,
    config_path: str | None = None,
    schema_dir_path: str | None = None,
) -> Path:
    base_url, key = load_config(config_path)
    schema_dir = find_schema_dir(schema_dir_path)
    if schema_dir is None:
        print(
            "Note: no money.json found, so CSV columns are derived from the "
            "returned rows.\n      The JSON files are unaffected. Keep a copy "
            "of the app's supabase/ folder\n      beside this script to "
            "restore full column ordering.\n"
        )
    token = sign_in(base_url, key, email, password)
    headers = {"apikey": key, "Authorization": f"Bearer {token}"}

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest = out_root / f"money-backup-{stamp}"
    data_dir = dest / "data"
    data_dir.mkdir(parents=True)

    columns_by_table = schema_columns(schema_dir)
    manifest_tables: dict[str, dict] = {}
    mismatches: list[str] = []

    for table in TABLES:
        expected = table_count(base_url, headers, table)
        rows = fetch_table(base_url, headers, table)
        (data_dir / f"{table}.json").write_text(
            json.dumps(rows, indent=2, ensure_ascii=False, sort_keys=True)
        )
        columns = columns_by_table.get(table)
        if not columns:
            # No schema snapshot: fall back to the union of keys present, so
            # a CSV is still produced rather than silently skipped.
            seen: list[str] = []
            for row in rows:
                for k in row:
                    if k not in seen:
                        seen.append(k)
            columns = seen
        if columns:
            write_csv(data_dir / f"{table}.csv", rows, columns)

        complete = len(rows) == expected
        if not complete:
            mismatches.append(
                f"{table}: server reported {expected} rows, downloaded {len(rows)}"
            )
        manifest_tables[table] = {
            "rows_downloaded": len(rows),
            "rows_on_server": expected,
            "complete": complete,
        }
        status = "ok" if complete else "MISMATCH"
        print(f"  {table:<14} {len(rows):>7} rows  [{status}]")

    if schema_dir is not None:
        schema_out = dest / "schema"
        schema_out.mkdir()
        for name in (SCHEMA_JSON_NAME, SCHEMA_SQL_NAME):
            src = schema_dir / name
            if src.exists():
                shutil.copy2(src, schema_out / name)

    manifest = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "supabase_url": base_url,
        "tables": manifest_tables,
        "total_rows": sum(t["rows_downloaded"] for t in manifest_tables.values()),
        "complete": not mismatches,
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2))

    if mismatches:
        raise BackupError(
            "Backup is INCOMPLETE — kept for inspection at "
            f"{dest}\n  " + "\n  ".join(mismatches)
        )
    return dest


def update_latest_symlink(out_root: Path, dest: Path) -> None:
    link = out_root / "latest"
    try:
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(dest.name)
    except OSError:
        pass  # A symlink is a convenience; never fail a good backup over it.


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Back up the Money Supabase project to a folder.",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Destination folder; a timestamped subfolder is created inside it.",
    )
    parser.add_argument(
        "--email",
        default=os.environ.get("SUPABASE_EMAIL"),
        help="Supabase account email (or set SUPABASE_EMAIL).",
    )
    parser.add_argument(
        "--config",
        help="Path to sync_config.json. Defaults to one beside this script, "
        "then the app repo's config/sync_config.json.",
    )
    parser.add_argument(
        "--schema-dir",
        help="Folder holding money.json and schema.sql, copied into each "
        "backup. Defaults to one beside this script, then the app repo's "
        "supabase/.",
    )
    args = parser.parse_args()

    email = args.email or input("Supabase email: ").strip()
    # Prompted, not stored: the password must not end up in a config file,
    # in shell history, or in the backup itself.
    password = os.environ.get("SUPABASE_PASSWORD") or getpass.getpass(
        f"Supabase password for {email}: "
    )
    if not email or not password:
        print("Email and password are required.", file=sys.stderr)
        return 2

    out_root = Path(args.out).expanduser().resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    try:
        dest = run_backup(
            out_root, email, password, args.config, args.schema_dir
        )
    except BackupError as exc:
        print(f"\nBackup failed: {exc}", file=sys.stderr)
        return 1

    update_latest_symlink(out_root, dest)
    print(f"\nBackup complete: {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())


# ---------------------------------------------------------------------------
# The other half of a backup strategy
# ---------------------------------------------------------------------------
#
# This script protects your *data*: it needs nothing but your app login, runs
# anywhere Python does, and produces files you can read in twenty years with a
# text editor. That is the backup that matters if the project is deleted or
# you lose access to the dashboard.
#
# It is not a restorable database dump. It does not capture auth users, roles,
# grants, RLS policies as executable SQL, or the server_updated_at trigger —
# though supabase/schema.sql, copied into every backup, does recreate the
# tables, policies and trigger by hand.
#
# For a true dump, use Postgres' own tooling with the connection string from
# the Supabase dashboard (Project Settings -> Database). It needs the database
# password, which is separate from your account password:
#
#     pg_dump "$MONEY_DB_URL" --clean --if-exists --no-owner --no-privileges \
#       -f money-dump.sql
#
# Restore into a fresh project with:
#
#     psql "$NEW_DB_URL" -f money-dump.sql
#
# Run pg_dump from Postgres 15 or newer, or it will refuse to talk to
# Supabase's server (`server version mismatch`). On macOS: brew install
# libpq, then use /opt/homebrew/opt/libpq/bin/pg_dump.
#
# Belt and braces: the app's own Settings -> Export writes the same data
# straight from the device's local SQLite, which is a third independent copy
# that does not depend on Supabase being reachable at all.
