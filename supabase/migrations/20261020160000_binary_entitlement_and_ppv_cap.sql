-- Award package-weighted binary shares and enforce the shopping/affiliate PPV cap
-- at the delivered-order ledger boundary. Existing data is not rewritten.

create or replace function private.binary_live_shares(p_end timestamptz default clock_timestamp())
returns table(
  member_id uuid,
  package_code text,
  package_version integer,
  binary_entitlement numeric,
  left_available numeric,
  right_available numeric,
  completed_shares numeric,
  consumed_each numeric
)
language sql
stable
security definer
set search_path to ''
as $function$
with cfg as (
  select private.current_mlm_rules() j, private.financial_reset_at() cutoff
),
ap as (
  select distinct on (a.member_id)
    a.member_id,
    a.package_code,
    a.package_version,
    coalesce(
      (cfg.j->'plans'->a.package_code->>'binary_entitlement')::numeric,
      a.binary_entitlement
    ) entitlement
  from public.package_activations a
  cross join cfg
  join public.member_profiles mp
    on mp.user_id = a.member_id
   and mp.status = 'active'
  where a.status = 'approved'
    and coalesce(a.activated_at, a.requested_at) <= p_end
  order by a.member_id, a.base_value desc, a.activated_at desc, a.requested_at desc
),
v as (
  select
    pl.member_id,
    coalesce(sum(pl.amount) filter (where pl.side = 'LEFT'), 0) l,
    coalesce(sum(pl.amount) filter (where pl.side = 'RIGHT'), 0) r
  from public.point_ledger pl
  cross join cfg
  where pl.point_type = 'BP'
    and pl.created_at > cfg.cutoff
    and pl.created_at <= p_end
  group by pl.member_id
),
c as (
  select
    r.member_id,
    coalesce(sum(r.consumed_left), 0) l,
    coalesce(sum(r.consumed_right), 0) r
  from public.binary_member_results r
  join public.binary_cycles bc on bc.id = r.cycle_id
  cross join cfg
  where bc.status in ('posted', 'unallocated')
    and bc.created_at > cfg.cutoff
  group by r.member_id
),
x as (
  select
    ap.*,
    greatest(coalesce(v.l, 0) - coalesce(c.l, 0), 0) la,
    greatest(coalesce(v.r, 0) - coalesce(c.r, 0), 0) ra,
    coalesce((cfg.j->>'binary_share_points_each_side')::numeric, 50) sp
  from ap
  cross join cfg
  left join v on v.member_id = ap.member_id
  left join c on c.member_id = ap.member_id
)
select
  member_id,
  package_code,
  package_version,
  entitlement,
  la,
  ra,
  trunc(trunc(least(la, ra) / sp, 1) * entitlement, 4),
  trunc(least(la, ra) / sp, 1) * sp
from x
where sp > 0
$function$;

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  cutoff timestamptz := private.financial_reset_at();
  pend timestamptz := clock_timestamp();
  pstart timestamptz;
  cycle uuid := gen_random_uuid();
  code text;
  wallet numeric := 0;
  shares numeric := 0;
  pool numeric := 0;
  m record;
  gross numeric;
  pay numeric;
  txn uuid;
  k text;
begin
  if auth.uid() is null or not private.has_role('admin') then
    raise exception 'Admin access required';
  end if;
  if p_share_value is null or p_share_value <= 0 then
    raise exception 'Enter a share price greater than zero';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement', 0));
  select coalesce(max(ends_at), cutoff)
    into pstart
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;

  select greatest(
    0,
    coalesce((select sum(binary_reserve_mio) from public.package_activations where status = 'approved' and source <> 'SHOPPING_PPV' and coalesce(activated_at, requested_at) > cutoff), 0)
    + coalesce((select sum(pool_amount) from public.shopping_reward_events where created_at > cutoff), 0)
    - coalesce((select sum(pool_amount) from public.binary_cycles where status in ('posted', 'unallocated') and created_at > cutoff), 0)
  ) into wallet;

  select coalesce(sum(completed_shares), 0)
    into shares
  from private.binary_live_shares(pend);

  if shares <= 0 then raise exception 'No payable binary shares are available'; end if;
  pool := trunc(p_share_value * shares, 4);
  if pool > wallet + .00000001 then
    raise exception 'Share price exceeds current binary pool wallet';
  end if;

  code := 'REALTIME-' || to_char(pend at time zone 'Asia/Karachi', 'YYYYMMDD-HH24MISS-MS');
  insert into public.binary_cycles(
    id, cycle_code, starts_at, ends_at, cycle_timezone, eligible_base,
    pool_rate, pool_amount, total_completed_shares, gross_share_value, status
  ) values (
    cycle, code, pstart, pend, 'Asia/Karachi', 0,
    0, pool, shares, p_share_value, 'frozen'
  );

  for m in
    select * from private.binary_live_shares(pend)
    where completed_shares > 0
    order by member_id
  loop
    gross := trunc(p_share_value * m.completed_shares, 4);
    pay := gross;

    insert into public.binary_member_results(
      cycle_id, member_id, package_code, package_version,
      left_available, right_available, completed_shares, entitlement,
      gross_amount, member_amount, company_retention,
      consumed_left, consumed_right, carry_left, carry_right,
      qualification_snapshot
    ) values (
      cycle, m.member_id, m.package_code, m.package_version,
      m.left_available, m.right_available, m.completed_shares, m.binary_entitlement,
      gross, pay, 0,
      m.consumed_each, m.consumed_each,
      m.left_available - m.consumed_each, m.right_available - m.consumed_each,
      jsonb_build_object(
        'qualification', 'realtime_package_weighted_share',
        'share_increment', .1,
        'share_price', p_share_value,
        'awarded_shares', m.completed_shares,
        'package_entitlement_snapshot', m.binary_entitlement,
        'consumed_each_side', m.consumed_each,
        'lifetime_bp_preserved', true
      )
    );

    if pay > 0 then
      k := 'binary:' || cycle::text || ':' || m.member_id::text;
      insert into public.bonus_transactions(
        beneficiary_id, method, cycle_id, qualifying_base, rate,
        gross_amount, payable_amount, currency, formula_version,
        calculation_trace, status, idempotency_key
      ) values (
        m.member_id, 'binary_pool_share', cycle, gross, m.binary_entitlement,
        gross, pay, 'MIO', 'realtime-binary-pool-v4',
        jsonb_build_object(
          'awarded_shares', m.completed_shares,
          'share_price', p_share_value,
          'package_entitlement_snapshot', m.binary_entitlement,
          'consumed_each_side', m.consumed_each,
          'pool_before', wallet,
          'pool_after', wallet - pool,
          'company_retention', 0
        ),
        'posted', k
      ) returning id into txn;

      update public.mio_wallet_accounts
      set balance = balance + pay, updated_at = now()
      where member_id = m.member_id;
      if not found then raise exception 'Member wallet missing'; end if;

      insert into public.mio_ledger(
        member_id, amount, action, bonus_transaction_id, cycle_id,
        reason, idempotency_key
      ) values (
        m.member_id, pay, 'bonus_credit', txn, cycle,
        'Real-time Binary Pool Share', 'binary-mio:' || txn::text
      );
    end if;
  end loop;

  update public.binary_cycles
  set status = 'posted', closed_at = clock_timestamp()
  where id = cycle;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, after_data)
  values (
    auth.uid(), 'BINARY_REALTIME_DISTRIBUTED', 'binary_cycle', cycle,
    jsonb_build_object(
      'pool_before', wallet,
      'distributed_pool', pool,
      'pool_after', wallet - pool,
      'awarded_shares', shares,
      'share_price', p_share_value
    )
  );

  return jsonb_build_object(
    'cycle_id', cycle,
    'cycle_code', code,
    'share_price', p_share_value,
    'distributed_shares', shares,
    'distributed_amount', pool,
    'remaining_pool', wallet - pool
  );
end
$function$;

create or replace function private.release_order_rewards()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  o public.orders%rowtype;
  ppv numeric;
  total numeric;
  funding numeric;
  r record;
  outcome jsonb;
  dp_base numeric;
  gp_base numeric;
  bp_base numeric;
  cap numeric := 110;
  used numeric := 0;
begin
  select * into o from public.orders where id = new.id for update;
  if o.status in ('cancelled', 'returned') and o.rewards_credited_at is null then
    update public.ecommerce_rewards set status = 'cancelled' where order_id = o.id and status = 'pending_delivery';
    return new;
  end if;
  if o.status <> 'delivered' or o.payment_status <> 'confirmed' or o.rewards_credited_at is not null then
    return new;
  end if;

  select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot, unit_price_pkr / o.usd_to_pkr_rate) * quantity, 4)), 0)
    into ppv
  from public.order_items
  where order_id = o.id;

  if o.reward_owner_id is null then
    update public.orders set rewards_credited_at = now(), ppv_generated = 0 where id = o.id;
    perform private.sync_company_treasury();
    return new;
  end if;

  if o.reward_mode = 'PPV' then
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
    where pl.member_id = o.reward_owner_id
      and pl.point_type = 'PPV'
      and pl.source_order_id is not null
      and pl.amount > 0
      and pl.created_at > private.financial_reset_at();

    ppv := least(ppv, greatest(0, cap - used));
  end if;

  if o.reward_version = 1 then
    o.reward_owner_id := o.buyer_id;
    perform private.post_shopping_rewards(o.id);
  else
    select coalesce(sum(a.amount_pkr), 0)
      into funding
    from public.commission_allocations a
    join public.order_items i on i.id = a.order_item_id
    where i.order_id = o.id and a.share_kind = 'network_rewards';

    if ppv * 300 > funding then raise exception 'Order rewards exceed verified funding'; end if;

    if o.reward_mode = 'MIO' then
      for r in select id from public.ecommerce_rewards where order_id = o.id order by id loop
        perform private.credit_ecommerce_reward(r.id);
      end loop;
      update public.orders set rewards_credited_at = now(), ppv_generated = 0 where id = o.id;
      perform private.sync_company_treasury();
      return new;
    elsif ppv > 0 then
      dp_base := trunc(ppv * coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric, 1), 4);
      gp_base := trunc(dp_base * coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric, .5), 4);
      bp_base := trunc(dp_base * coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric, .5), 4);

      insert into public.shopping_reward_events(
        order_id, buyer_id, funded_pkr, bv, dp, gp, bp, binary_reserve_mio
      ) values (
        o.id, o.reward_owner_id, funding, ppv, dp_base, gp_base, bp_base,
        trunc(bp_base * coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric, .35), 4)
      ) on conflict do nothing;

      if found then
        outcome := private.distribute_mlm_event(o.reward_owner_id, ppv, o.id, null, o.rules_snapshot);
        update public.shopping_reward_events
        set direct_generation_mio = (outcome->>'direct_generation')::numeric,
            single_line_mio = (outcome->>'single_line')::numeric
        where order_id = o.id;
      end if;
    end if;
  end if;

  if ppv > 0 then
    insert into public.point_ledger(
      member_id, point_type, amount, source_order_id, entry_kind, idempotency_key
    ) values (
      o.reward_owner_id, 'PPV', ppv, o.id, 'credit', 'order:' || o.id::text || ':ppv'
    ) on conflict (idempotency_key) do nothing;
  end if;

  if o.reward_mode = 'PPV' and used + ppv >= cap then
    update public.member_profiles
    set shopping_reward_mode = 'MIO', updated_at = now()
    where user_id = o.reward_owner_id;
  end if;

  update public.orders
  set ppv_generated = ppv, rewards_credited_at = now()
  where id = o.id;

  select coalesce(sum(amount), 0)
    into total
  from public.point_ledger
  where member_id = o.reward_owner_id and point_type = 'PPV';

  perform private.activate_next_ppv_package(o.reward_owner_id, o.id, total);
  perform private.sync_company_treasury();
  return new;
end
$function$;

create or replace function public.ecommerce_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  uid uuid := auth.uid();
  adm boolean := private.has_role('admin');
  cutoff timestamptz := private.financial_reset_at();
  cap numeric := 110;
  used numeric := 0;
begin
  if uid is null then raise exception 'Sign in first'; end if;

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
    and pl.source_order_id is not null
    and pl.amount > 0
    and pl.created_at > cutoff;

  return jsonb_build_object(
    'mode', (select shopping_reward_mode from public.member_profiles where user_id = uid),
    'eligible', private.package_eligible(uid),
    'shopping_ppv_used', used,
    'shopping_ppv_cap', cap,
    'shopping_ppv_locked', used >= cap,
    'team_ppv_cap', cap,
    'totals', coalesce((
      select jsonb_agg(x) from (
        select reward_kind, status, sum(amount) amount
        from public.ecommerce_rewards
        where (beneficiary_id = uid or adm) and created_at > cutoff
        group by 1, 2
      ) x
    ), '[]'),
    'rows', coalesce((
      select jsonb_agg(x) from (
        select e.*, o.order_code, m.full_name, m.member_code,
               src.full_name source_name, src.member_code source_code,
               i.product_name_snapshot
        from public.ecommerce_rewards e
        join public.orders o on o.id = e.order_id
        join public.order_items i on i.id = e.order_item_id
        left join public.member_profiles m on m.user_id = e.beneficiary_id
        left join public.member_profiles src on src.user_id = o.reward_owner_id
        where (e.beneficiary_id = uid or adm) and e.created_at > cutoff
        order by e.created_at desc, e.id
        limit 200
      ) x
    ), '[]'),
    'ppv_orders', coalesce((
      select jsonb_agg(x) from (
        select o.id, o.order_code, o.status, o.payment_status,
               o.reward_ppv_total, o.ppv_generated,
               o.rewards_credited_at, o.selling_affiliate_id
        from public.orders o
        where reward_owner_id = uid and reward_mode = 'PPV' and o.created_at > cutoff
        order by created_at desc
        limit 100
      ) x
    ), '[]'),
    'top_earners', case when adm then coalesce((
      select jsonb_agg(x) from (
        select m.full_name, m.member_code, sum(e.amount) income
        from public.ecommerce_rewards e
        join public.member_profiles m on m.user_id = e.beneficiary_id
        where e.status = 'posted' and e.created_at > cutoff
        group by m.user_id
        order by sum(e.amount) desc
        limit 10
      ) x
    ), '[]') else '[]'::jsonb end
  );
end
$function$;

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
    and pl.source_order_id is not null
    and pl.amount > 0
    and pl.created_at > private.financial_reset_at();

  if p_mode = 'PPV' and used >= cap then
    raise exception 'Your shopping PPV cap of 110 is complete. MIO mode is now required.';
  end if;

  update public.member_profiles
  set shopping_reward_mode = p_mode, updated_at = now()
  where user_id = uid;
end
$function$;

