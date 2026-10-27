-- The legacy trigger counted package activation PPV as shopping PPV and could
-- lock the preference before the dedicated shopping/affiliate cap was reached.
drop trigger if exists trg_lock_reward_mode_at_ppv_cap on public.point_ledger;
drop function if exists private.lock_reward_mode_at_ppv_cap();

-- Cover the source lookups used by wallet history and reconciliation.
create index if not exists income_wallet_ledger_source_bonus_idx
  on public.income_wallet_ledger(source_bonus_id)
  where source_bonus_id is not null;

create index if not exists income_wallet_ledger_source_reward_idx
  on public.income_wallet_ledger(source_reward_id)
  where source_reward_id is not null;
