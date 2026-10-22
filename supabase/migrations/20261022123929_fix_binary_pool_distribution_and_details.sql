-- Fix the live binary pool settlement wallet calculation and expose an
-- admin-only, member-wise explanation of the currently available shares.

create or replace function public.admin_binary_pool_dashboard()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  admin_id uuid := auth.uid();
  cutoff timestamptz := private.financial_reset_at();
  last_end timestamptz;
  period_start timestamptz;
  period_end timestamptz := clock_timestamp();
  total_generated numeric := 0;
  total_distributed numeric := 0;
  pool_wallet numeric := 0;
  current_cycle_balance numeric := 0;
  last_distributed numeric := 0;
  total_shares numeric := 0;
  package_json jsonb := '[]'::jsonb;
  detail_json jsonb := '[]'::jsonb;
  cfg jsonb;
  share_points numeric;
begin
  if admin_id is null or not private.has_role('admin') then
    raise exception 'Admin access required';
  end if;

  cfg := private.current_mlm_rules();
  share_points := coalesce((cfg->>'binary_share_points_each_side')::numeric, 50);
  if share_points <= 0 then share_points := 50; end if;

  select max(ends_at) into last_end
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;
  period_start := coalesce(last_end, cutoff);

  select
    coalesce((select sum(binary_reserve_mio) from public.package_activations
      where status = 'approved' and source <> 'SHOPPING_PPV'
        and coalesce(activated_at, requested_at) > cutoff), 0)
    + coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events
      where created_at > cutoff), 0)
  into total_generated;

  select coalesce(sum(pool_amount), 0) into total_distributed
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;
  pool_wallet := greatest(0, total_generated - total_distributed);

  select
    coalesce((select sum(binary_reserve_mio) from public.package_activations
      where status = 'approved' and source <> 'SHOPPING_PPV'
        and coalesce(activated_at, requested_at) > period_start), 0)
    + coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events
      where created_at > period_start), 0)
  into current_cycle_balance;

  select coalesce(sum(completed_shares), 0) into total_shares
  from private.binary_live_shares(period_end);

  select coalesce(jsonb_agg(jsonb_build_object(
    'package_code', package_code,
    'shares', shares
  ) order by package_code), '[]'::jsonb)
  into package_json
  from (
    select package_code, sum(completed_shares) shares
    from private.binary_live_shares(period_end)
    group by package_code
    having sum(completed_shares) > 0
  ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', s.member_id,
    'member_name', mp.full_name,
    'member_code', mp.member_code,
    'package_code', s.package_code,
    'left_bp', s.left_available,
    'right_bp', s.right_available,
    'raw_shares', trunc(least(s.left_available, s.right_available) / share_points, 1),
    'entitlement', s.binary_entitlement,
    'entitlement_percent', trunc(s.binary_entitlement * 100, 2),
    'final_shares', s.completed_shares,
    'consumed_each_side', s.consumed_each
  ) order by s.completed_shares desc, mp.member_code), '[]'::jsonb)
  into detail_json
  from private.binary_live_shares(period_end) s
  left join public.member_profiles mp on mp.user_id = s.member_id
  where s.completed_shares > 0;

  select coalesce(pool_amount, 0) into last_distributed
  from public.binary_cycles
  where status = 'posted' and created_at > cutoff
  order by ends_at desc
  limit 1;

  return jsonb_build_object(
    'total_pool_generated', total_generated,
    'total_distributed', total_distributed,
    'total_pool_wallet', pool_wallet,
    'current_cycle_balance', current_cycle_balance,
    'last_distributed', last_distributed,
    'total_shares', total_shares,
    'shares_by_package', package_json,
    'share_details', detail_json,
    'share_points_each_side', share_points,
    'period_start', period_start,
    'period_end', period_end,
    'can_distribute', total_shares > 0 and pool_wallet > 0,
    'default_share_value', 0,
    'next_cycle_code', 'ONDEMAND-' || to_char(period_end at time zone 'Asia/Karachi', 'YYYYMMDD-HH24MISS')
  );
end
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
  select coalesce(max(ends_at), cutoff) into pstart
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;

  select greatest(
    0,
    coalesce((select sum(binary_reserve_mio) from public.package_activations
      where status = 'approved' and source <> 'SHOPPING_PPV'
        and coalesce(activated_at, requested_at) > cutoff), 0)
    + coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events
      where created_at > cutoff), 0)
    - coalesce((select sum(pool_amount) from public.binary_cycles
      where status in ('posted', 'unallocated') and created_at > cutoff), 0)
  ) into wallet;

  select coalesce(sum(completed_shares), 0) into shares
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

revoke all on function public.admin_binary_pool_dashboard() from public, anon;
revoke all on function public.admin_distribute_binary_pool(numeric) from public, anon;
grant execute on function public.admin_binary_pool_dashboard() to authenticated, service_role;
grant execute on function public.admin_distribute_binary_pool(numeric) to authenticated, service_role;
