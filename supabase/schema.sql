-- Money - Supabase schema
-- Run this once in your Supabase project's SQL editor (Dashboard > SQL Editor).
--
-- Then create your user: Dashboard > Authentication > Users > Add user
-- (email + password, "Auto confirm user" on). Sign in with that email and
-- password in the app's Settings > Sync screen on each device.

create table if not exists accounts (
  id text primary key,
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

-- Single-user app: any authenticated user gets full access.
alter table accounts enable row level security;
alter table categories enable row level security;
alter table transactions enable row level security;
alter table fx_rates enable row level security;

create policy "authenticated full access" on accounts
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on categories
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on transactions
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on fx_rates
  for all to authenticated using (true) with check (true);
