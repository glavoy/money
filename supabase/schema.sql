-- Money - Supabase schema
-- Run this once in your Supabase project's SQL editor (Dashboard > SQL Editor).
--
-- Then create your user: Dashboard > Authentication > Users > Add user
-- (email + password, "Auto confirm user" on). Sign in with that email and
-- password in the app's Settings > Sync screen on each device.

create table if not exists ledgers (
  id text primary key,
  name text not null,
  archived boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

insert into ledgers (
  id, name, archived, sort_order, created_at, updated_at, deleted
) values (
  'ledger-personal', 'Personal', false, 0, '2000-01-01T00:00:00Z', '2000-01-01T00:00:00Z', false
) on conflict (id) do nothing;

create table if not exists accounts (
  id text primary key,
  ledger_id text not null default 'ledger-personal',
  name text not null,
  type text not null,
  currency text not null,
  opening_balance double precision not null default 0,
  opening_date timestamptz,
  archived boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

create table if not exists categories (
  id text primary key,
  ledger_id text not null default 'ledger-personal',
  name text not null,
  kind text not null,
  sort_order integer not null default 0,
  color bigint,
  archived boolean not null default false,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

create table if not exists transactions (
  id text primary key,
  ledger_id text not null default 'ledger-personal',
  date timestamptz not null,
  kind text not null,
  amount double precision not null,
  account_id text not null,
  category_id text,
  to_account_id text,
  to_amount double precision,
  note text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

alter table accounts
  add column if not exists ledger_id text not null default 'ledger-personal';
alter table categories
  add column if not exists ledger_id text not null default 'ledger-personal';
alter table transactions
  add column if not exists ledger_id text not null default 'ledger-personal';

create index if not exists accounts_ledger_id_idx on accounts (ledger_id);
create index if not exists categories_ledger_id_idx on categories (ledger_id);
create index if not exists transactions_ledger_id_idx on transactions (ledger_id);
create index if not exists transactions_updated_at_idx on transactions (updated_at);
create index if not exists transactions_date_idx on transactions (date);

create table if not exists fx_rates (
  id text primary key,
  date timestamptz not null unique,
  usd_ugx double precision,
  cad_ugx double precision,
  usd_cad double precision,
  source text not null default 'api',
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

create index if not exists fx_rates_updated_at_idx on fx_rates (updated_at);

-- server_updated_at is stamped by Postgres at commit time (never by the
-- client) and is what incremental pulls filter/order on. updated_at stays
-- client-stamped and is what last-write-wins conflict resolution uses. This
-- split means a device that's been offline for any length of time is still
-- guaranteed to see everything it missed, because no client clock or push
-- delay can put a row "behind" another device's pull cursor. See
-- money_stamp_server_updated_at() below.
alter table ledgers add column if not exists server_updated_at timestamptz not null default clock_timestamp();
alter table accounts add column if not exists server_updated_at timestamptz not null default clock_timestamp();
alter table categories add column if not exists server_updated_at timestamptz not null default clock_timestamp();
alter table transactions add column if not exists server_updated_at timestamptz not null default clock_timestamp();
alter table fx_rates add column if not exists server_updated_at timestamptz not null default clock_timestamp();

create index if not exists ledgers_server_updated_at_idx on ledgers (server_updated_at);
create index if not exists accounts_server_updated_at_idx on accounts (server_updated_at);
create index if not exists categories_server_updated_at_idx on categories (server_updated_at);
create index if not exists transactions_server_updated_at_idx on transactions (server_updated_at);
create index if not exists fx_rates_server_updated_at_idx on fx_rates (server_updated_at);

-- Stamps server_updated_at with the actual commit-time clock (overriding
-- anything the client sends), and rejects an update that would clobber a
-- newer edit with a stale one — e.g. a device that was offline for a while
-- pushing an old version after a newer edit already synced from elsewhere.
create or replace function money_stamp_server_updated_at()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return old;
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists ledgers_stamp_server_updated_at on ledgers;
create trigger ledgers_stamp_server_updated_at
  before insert or update on ledgers
  for each row execute function money_stamp_server_updated_at();

drop trigger if exists accounts_stamp_server_updated_at on accounts;
create trigger accounts_stamp_server_updated_at
  before insert or update on accounts
  for each row execute function money_stamp_server_updated_at();

drop trigger if exists categories_stamp_server_updated_at on categories;
create trigger categories_stamp_server_updated_at
  before insert or update on categories
  for each row execute function money_stamp_server_updated_at();

drop trigger if exists transactions_stamp_server_updated_at on transactions;
create trigger transactions_stamp_server_updated_at
  before insert or update on transactions
  for each row execute function money_stamp_server_updated_at();

drop trigger if exists fx_rates_stamp_server_updated_at on fx_rates;
create trigger fx_rates_stamp_server_updated_at
  before insert or update on fx_rates
  for each row execute function money_stamp_server_updated_at();

-- Single-user app: any authenticated user gets full access.
alter table ledgers enable row level security;
alter table accounts enable row level security;
alter table categories enable row level security;
alter table transactions enable row level security;
alter table fx_rates enable row level security;

create policy "authenticated full access" on ledgers
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on accounts
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on categories
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on transactions
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on fx_rates
  for all to authenticated using (true) with check (true);
