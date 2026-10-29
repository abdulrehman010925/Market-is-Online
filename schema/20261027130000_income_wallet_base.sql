-- The live project has these wallet tables. Include their base definitions
-- before the routing migrations so a fresh schema replay matches production.
create table if not exists public.member_income_wallets (
  member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
  proceed_mio numeric not null default 0 check (proceed_mio>=0),
  shopping_points numeric not null default 0 check (shopping_points>=0),
  promotion_points numeric not null default 0 check (promotion_points>=0),
  updated_at timestamptz not null default now()
);
create table if not exists public.income_wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.member_profiles(user_id) on delete cascade,
  wallet_kind text not null check (wallet_kind in ('cash','proceed','shopping','promotion','fee')),
  amount numeric not null check (amount<>0),
  entry_kind text not null,
  source_bonus_id uuid references public.bonus_transactions(id),
  source_reward_id uuid references public.ecommerce_rewards(id),
  conversion_id uuid,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);
create index income_wallet_ledger_member_created_idx on public.income_wallet_ledger(member_id,created_at desc);
create index income_wallet_ledger_kind_created_idx on public.income_wallet_ledger(wallet_kind,created_at desc);
create index income_wallet_ledger_source_bonus_idx on public.income_wallet_ledger(source_bonus_id) where source_bonus_id is not null;
create index income_wallet_ledger_source_reward_idx on public.income_wallet_ledger(source_reward_id) where source_reward_id is not null;

alter table public.member_income_wallets enable row level security;
alter table public.income_wallet_ledger enable row level security;
create policy "members read own income wallets" on public.member_income_wallets
for select to authenticated using ((select auth.uid())=member_id);
create policy "members read own income wallet ledger" on public.income_wallet_ledger
for select to authenticated using ((select auth.uid())=member_id);
revoke all on public.member_income_wallets,public.income_wallet_ledger from public,anon,authenticated;
grant select on public.member_income_wallets,public.income_wallet_ledger to authenticated;
