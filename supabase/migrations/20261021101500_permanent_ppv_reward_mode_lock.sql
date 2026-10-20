-- Keep the reward preference permanently locked to MIO once a member reaches the configured PPV cap.
create or replace function public.set_shopping_reward_mode(p_mode text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid := auth.uid();
  cap numeric := 110;
  used numeric := 0;
begin
  if uid is null or not private.package_eligible(uid) then
    raise exception 'Activate any package to choose MIO rewards';
  end if;
  if p_mode is null or p_mode not in ('PPV', 'MIO') then
    raise exception 'Choose PPV or MIO';
  end if;

  select coalesce((
    select (config_value->>'shopping_ppv_cap')::numeric
    from public.system_config
    where config_key = 'PPV_CAPS' and effective_to is null
    order by version desc
    limit 1
  ), 110) into cap;

  select coalesce(sum(pl.amount), 0)
    into used
  from public.point_ledger pl
  where pl.member_id = uid
    and pl.point_type = 'PPV'
    and pl.amount > 0
    and pl.created_at > private.financial_reset_at();

  if p_mode = 'PPV' and used >= cap then
    raise exception 'Your PPV cap of % is complete. MIO mode is now required.', cap;
  end if;

  update public.member_profiles
  set shopping_reward_mode = p_mode, updated_at = now()
  where user_id = uid;
end
$function$;

revoke all on function public.set_shopping_reward_mode(text) from public, anon;
grant execute on function public.set_shopping_reward_mode(text) to authenticated;

create or replace function private.lock_reward_mode_at_ppv_cap()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  cap numeric := 110;
  used numeric := 0;
begin
  if new.point_type <> 'PPV' or coalesce(new.amount, 0) <= 0 then
    return new;
  end if;

  select coalesce((
    select (config_value->>'shopping_ppv_cap')::numeric
    from public.system_config
    where config_key = 'PPV_CAPS' and effective_to is null
    order by version desc
    limit 1
  ), 110) into cap;

  select coalesce(sum(pl.amount), 0)
    into used
  from public.point_ledger pl
  where pl.member_id = new.member_id
    and pl.point_type = 'PPV'
    and pl.amount > 0
    and pl.created_at > private.financial_reset_at();

  if used >= cap then
    update public.member_profiles
    set shopping_reward_mode = 'MIO', updated_at = now()
    where user_id = new.member_id
      and shopping_reward_mode is distinct from 'MIO';
  end if;

  return new;
end
$function$;

drop trigger if exists trg_lock_reward_mode_at_ppv_cap on public.point_ledger;
create trigger trg_lock_reward_mode_at_ppv_cap
after insert or update of amount, point_type, member_id on public.point_ledger
for each row execute function private.lock_reward_mode_at_ppv_cap();

with cap_value as (
  select coalesce((
    select (config_value->>'shopping_ppv_cap')::numeric
    from public.system_config
    where config_key = 'PPV_CAPS' and effective_to is null
    order by version desc
    limit 1
  ), 110) as cap
), capped_members as (
  select pl.member_id
  from public.point_ledger pl
  cross join cap_value c
  where pl.point_type = 'PPV'
    and pl.amount > 0
    and pl.created_at > private.financial_reset_at()
  group by pl.member_id, c.cap
  having sum(pl.amount) >= c.cap
)
update public.member_profiles mp
set shopping_reward_mode = 'MIO', updated_at = now()
where mp.user_id in (select member_id from capped_members)
  and mp.shopping_reward_mode is distinct from 'MIO';
