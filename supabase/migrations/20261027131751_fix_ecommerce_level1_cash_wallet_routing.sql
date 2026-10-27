-- Route personal and level-1 e-commerce earnings to Cash Wallet.
-- Higher-level e-commerce earnings continue through Proceed Wallet.
create or replace function private.route_ecommerce_to_income_wallet()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  target text;
  inserted_count integer;
begin
  if new.status <> 'posted' or new.amount <= 0 or new.beneficiary_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status = 'posted' then
    return new;
  end if;

  target := case
    when new.reward_kind in ('cashback', 'affiliate', 'sponsor') then 'cash'
    else 'proceed'
  end;

  insert into public.member_income_wallets(member_id)
  values(new.beneficiary_id)
  on conflict(member_id) do nothing;

  insert into public.income_wallet_ledger(
    member_id,
    wallet_kind,
    amount,
    entry_kind,
    source_reward_id,
    note,
    metadata,
    idempotency_key
  )
  values(
    new.beneficiary_id,
    target,
    new.amount,
    'ecommerce_earning',
    new.id,
    case
      when target = 'cash' then 'E-commerce level 1 / personal earning'
      else 'E-commerce level 2+ earning'
    end,
    jsonb_build_object(
      'reward_kind', new.reward_kind,
      'rate', new.rate,
      'order_id', new.order_id
    ),
    'ecommerce-route:' || new.id
  )
  on conflict(idempotency_key) do nothing;

  get diagnostics inserted_count = row_count;

  if inserted_count = 1 and target = 'proceed' then
    update public.mio_wallet_accounts
    set balance = balance - new.amount,
        updated_at = now()
    where member_id = new.beneficiary_id
      and balance >= new.amount;

    if not found then
      raise exception 'E-commerce wallet routing reconciliation failed';
    end if;

    update public.member_income_wallets
    set proceed_mio = proceed_mio + new.amount,
        updated_at = now()
    where member_id = new.beneficiary_id;
  end if;

  return new;
end
$function$;
