-- One authoritative 110 PPV cap for self-shopping and attributed affiliate
-- orders. Package activation PPV is intentionally excluded from this cap.

create or replace function private.shopping_ppv_cap_status(p_member uuid)
returns table(cap numeric, used numeric, remaining numeric, locked boolean)
language sql
stable
security definer
set search_path to ''
as $function$
with settings as (
  select coalesce((
    select (config_value->>'shopping_ppv_cap')::numeric
    from public.system_config
    where config_key = 'PPV_CAPS' and effective_to is null
    order by version desc
    limit 1
  ), 110)::numeric as cap
), usage as (
  select coalesce(sum(pl.amount), 0)::numeric as used
  from public.point_ledger pl
  where pl.member_id = p_member
    and pl.point_type = 'PPV'
    and pl.source_order_id is not null
    and pl.amount > 0
    and pl.created_at > private.financial_reset_at()
)
select
  settings.cap,
  usage.used,
  greatest(settings.cap - usage.used, 0),
  usage.used >= settings.cap
from settings cross join usage
$function$;

revoke all on function private.shopping_ppv_cap_status(uuid) from public, anon, authenticated;

create or replace function public.my_ppv_cap_status()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  uid uuid := auth.uid();
  s record;
  mode text;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  select * into s from private.shopping_ppv_cap_status(uid);
  select shopping_reward_mode into mode from public.member_profiles where user_id = uid;
  return jsonb_build_object(
    'mode', case when s.locked then 'MIO' else coalesce(mode, 'PPV') end,
    'eligible', private.package_eligible(uid),
    'shopping_ppv_used', s.used,
    'shopping_ppv_cap', s.cap,
    'shopping_ppv_remaining', s.remaining,
    'shopping_ppv_locked', s.locked
  );
end
$function$;

revoke all on function public.my_ppv_cap_status() from public, anon;
grant execute on function public.my_ppv_cap_status() to authenticated;

create or replace function public.set_shopping_reward_mode(p_mode text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid := auth.uid();
  s record;
begin
  if uid is null or not private.package_eligible(uid) then
    raise exception 'Activate any package to choose MIO rewards';
  end if;
  if p_mode is null or p_mode not in ('PPV', 'MIO') then
    raise exception 'Choose PPV or MIO';
  end if;

  select * into s from private.shopping_ppv_cap_status(uid);
  if p_mode = 'PPV' and s.locked then
    update public.member_profiles
    set shopping_reward_mode = 'MIO', updated_at = now()
    where user_id = uid and shopping_reward_mode <> 'MIO';
    raise exception 'Your shopping PPV cap of % is complete. MIO mode is now required.', s.cap;
  end if;

  update public.member_profiles
  set shopping_reward_mode = p_mode, updated_at = now()
  where user_id = uid;
end
$function$;

create or replace function private.snapshot_order_reward_mode()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  code text := upper(trim(coalesce(current_setting('mio.affiliate_code', true), '')));
  seller uuid;
  cap_locked boolean := false;
begin
  if code <> '' then
    select user_id into seller
    from public.member_profiles
    where (
      upper(member_code) = code
      or upper(replace(member_code, 'MIO-', '')) = code
      or upper(referral_code) = regexp_replace(code, '-[LR]$', '')
    )
      and status in ('active', 'inactive')
      and terms_accepted_at is not null;
    if seller is null then raise exception 'Selling link is no longer valid'; end if;
  end if;

  if seller = new.buyer_id then seller := null; end if;
  new.selling_affiliate_id := seller;
  new.reward_owner_id := coalesce(seller, new.buyer_id);

  select case when private.package_eligible(user_id) then shopping_reward_mode else 'PPV' end,
         sponsor_id
    into new.reward_mode, new.reward_sponsor_id
  from public.member_profiles
  where user_id = new.reward_owner_id;

  if new.reward_owner_id is not null then
    select s.locked into cap_locked
    from private.shopping_ppv_cap_status(new.reward_owner_id) s;
  end if;

  if cap_locked then
    new.reward_mode := 'MIO';
    update public.member_profiles
    set shopping_reward_mode = 'MIO', updated_at = now()
    where user_id = new.reward_owner_id and shopping_reward_mode <> 'MIO';
  end if;

  select sponsor_id into new.reward_second_sponsor_id
  from public.member_profiles
  where user_id = new.reward_sponsor_id;
  new.reward_mode := coalesce(new.reward_mode, 'PPV');
  return new;
end
$function$;

-- Serialize simultaneous delivered orders for one reward owner so two orders
-- cannot both consume the same remaining PPV allowance.
create or replace function private.serialize_shopping_ppv_release()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.reward_owner_id is not null
     and new.reward_mode = 'PPV'
     and new.status = 'delivered'
     and new.payment_status = 'confirmed'
     and new.rewards_credited_at is null then
    perform pg_advisory_xact_lock(hashtextextended('shopping-ppv:' || new.reward_owner_id::text, 0));
  end if;
  return new;
end
$function$;

drop trigger if exists orders_serialize_shopping_ppv on public.orders;
create trigger orders_serialize_shopping_ppv
before update on public.orders
for each row execute function private.serialize_shopping_ppv_release();

create or replace function private.enforce_shopping_ppv_mode()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  is_locked boolean;
begin
  if new.point_type = 'PPV' and new.source_order_id is not null and new.amount > 0 then
    select s.locked into is_locked from private.shopping_ppv_cap_status(new.member_id) s;
    if is_locked then
      update public.member_profiles
      set shopping_reward_mode = 'MIO', updated_at = now()
      where user_id = new.member_id and shopping_reward_mode <> 'MIO';
    end if;
  end if;
  return new;
end
$function$;

drop trigger if exists point_ledger_enforce_shopping_ppv_mode on public.point_ledger;
create trigger point_ledger_enforce_shopping_ppv_mode
after insert or update of amount on public.point_ledger
for each row execute function private.enforce_shopping_ppv_mode();

-- Reconcile stale preferences without changing any balances or ledger rows.
update public.member_profiles mp
set shopping_reward_mode = 'MIO', updated_at = now()
where shopping_reward_mode <> 'MIO'
  and exists (
    select 1 from private.shopping_ppv_cap_status(mp.user_id) s where s.locked
  );
