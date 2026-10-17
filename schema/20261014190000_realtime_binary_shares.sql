-- Binary shares accrue in real time from matched BP. Admin may distribute at any time.
-- Shares are earned in 0.1 increments; distribution consumes only the matched BP
-- represented by the paid shares. Lifetime BP remains in point_ledger.

alter table public.binary_member_results
  alter column completed_shares type numeric(18,4) using completed_shares::numeric;

alter table public.binary_cycles
  alter column total_completed_shares type numeric(18,4) using total_completed_shares::numeric;

create or replace function public.admin_binary_pool_dashboard()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cutoff timestamptz:=private.financial_reset_at(); last_end timestamptz;
 period_start timestamptz; period_end timestamptz:=clock_timestamp(); total_wallet numeric:=0;
 current_pool numeric:=0; last_distributed numeric:=0; total_shares numeric:=0;
 package_json jsonb:='[]'::jsonb; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 cfg:=private.current_mlm_rules();
 share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then share_points:=50; end if;
 select max(ends_at) into last_end from public.binary_cycles
  where status in('posted','unallocated') and created_at>cutoff;
 period_start:=coalesce(last_end,cutoff);

 select greatest(0,
   coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)
   +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)
   -coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated') and created_at>cutoff),0))
 into total_wallet;
 current_pool:=total_wallet;

 with active_package as (
  select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,
   coalesce((cfg->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
  from public.package_activations a
  join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
  where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=period_end
  order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
 ), volume as (
  select pl.member_id,
   coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,
   coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
  from public.point_ledger pl
  where pl.point_type='BP' and pl.created_at>cutoff and pl.created_at<=period_end
  group by pl.member_id
 ), consumed as (
  select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
  from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
  where c.status in('posted','unallocated') and c.created_at>cutoff group by r.member_id
 ), shares as (
  select ap.package_code,
   trunc(least(greatest(coalesce(v.l,0)-coalesce(c.l,0),0),greatest(coalesce(v.r,0)-coalesce(c.r,0),0))/share_points,1) completed
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 )
 select coalesce(sum(shares),0),
  coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb)
 into total_shares,package_json
 from (select package_code,sum(completed) shares from shares group by package_code having sum(completed)>0) p;

 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles
  where status='posted' and created_at>cutoff order by ends_at desc limit 1;
 return jsonb_build_object(
  'total_pool_wallet',total_wallet,'current_pool',current_pool,'this_week_pool',current_pool,
  'last_distributed',last_distributed,'total_shares',coalesce(total_shares,0),
  'shares_by_package',package_json,'share_points_each_side',share_points,
  'period_start',period_start,'period_end',period_end,
  'can_distribute',coalesce(total_shares,0)>0 and total_wallet>0,
  'default_share_value',case when coalesce(total_shares,0)>0 then trunc(total_wallet/total_shares,4) else 0 end,
  'next_cycle_code','REALTIME-'||to_char(period_end at time zone 'Asia/Karachi','YYYYMMDD-HH24MISS'));
end;
$$;

create or replace function public.admin_close_binary_cycle(
 p_cycle_code text,p_starts_at timestamptz,p_ends_at timestamptz,p_timezone text,p_manual_share_value numeric default null)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cycle uuid:=gen_random_uuid(); cutoff timestamptz:=private.financial_reset_at();
 reserved_pool numeric:=0; pool numeric:=0; share_count numeric:=0; m record; gross numeric;
 member_pay numeric; remainder numeric; residual_recipient uuid; txn uuid; key text; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_manual_share_value is null or p_manual_share_value<0 then raise exception 'Enter a valid share price'; end if;
 if p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at or p_ends_at>clock_timestamp()+interval '5 seconds' then raise exception 'Invalid distribution period'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 cfg:=private.current_mlm_rules(); share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then raise exception 'Binary share points rule is invalid'; end if;
 if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Distribution reference already exists'; end if;
 select greatest(0,
   coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)
   +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)
   -coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated') and created_at>cutoff),0))
 into reserved_pool;
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
 values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,p_timezone,0,0,0,'open');

 for m in
  with active_package as (
   select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,
    coalesce((cfg->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
   from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
   where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=p_ends_at
   order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
  ), volume as (
   select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
   from public.point_ledger pl where pl.point_type='BP' and pl.created_at>cutoff and pl.created_at<=p_ends_at group by pl.member_id
  ), consumed as (
   select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
   from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
   where c.status in('posted','unallocated') and c.created_at>cutoff group by r.member_id
  )
  select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) l,greatest(coalesce(v.r,0)-coalesce(c.r,0),0) r
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 loop
  gross:=trunc(least(m.l,m.r)/share_points,1);
  if gross>0 then
   insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)
   values(cycle,m.member_id,m.package_code,m.package_version,m.l,m.r,gross,m.binary_entitlement,0,0,0,gross*share_points,gross*share_points,m.l-gross*share_points,m.r-gross*share_points,jsonb_build_object('qualification','active_package_and_realtime_fractional_share','share_points_each_side',share_points,'share_increment',0.1,'manual_share_price',p_manual_share_value));
  end if;
 end loop;
 select coalesce(sum(completed_shares),0) into share_count from public.binary_member_results where cycle_id=cycle;
 if share_count<=0 then raise exception 'No payable binary shares are available'; end if;
 pool:=trunc(p_manual_share_value*share_count,4);
 if pool>reserved_pool+.00000001 then raise exception 'Share price exceeds current binary pool wallet'; end if;
 update public.binary_cycles set pool_amount=pool,total_completed_shares=share_count,gross_share_value=p_manual_share_value,status='frozen' where id=cycle;
 update public.binary_member_results set gross_amount=trunc(p_manual_share_value*completed_shares,4),company_retention=trunc(p_manual_share_value*completed_shares,4) where cycle_id=cycle;
 select pool-coalesce(sum(gross_amount),0) into remainder from public.binary_member_results where cycle_id=cycle;
 for residual_recipient in select member_id from public.binary_member_results where cycle_id=cycle and completed_shares>0 order by member_id limit greatest(round(remainder*10000)::integer,0)
 loop update public.binary_member_results set gross_amount=gross_amount+0.0001,company_retention=company_retention+0.0001 where cycle_id=cycle and member_id=residual_recipient; end loop;
 for m in select * from public.binary_member_results where cycle_id=cycle order by member_id loop
  gross:=m.gross_amount; member_pay:=trunc(gross*m.entitlement,4);
  update public.binary_member_results set member_amount=member_pay,company_retention=gross-member_pay where cycle_id=cycle and member_id=m.member_id;
  if member_pay>0 then
   key:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
   values(m.member_id,'binary_pool_share',cycle,gross,m.entitlement,gross,member_pay,'MIO','realtime-binary-pool-v1',jsonb_build_object('completed_shares',m.completed_shares,'share_points_each_side',share_points,'share_price',p_manual_share_value,'consumed_left',m.consumed_left,'consumed_right',m.consumed_right,'lifetime_bp_preserved',true),'posted',key) returning id into txn;
   update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing'; end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)
   values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Real-time Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 update public.binary_cycles set status='posted',closed_at=clock_timestamp() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
 values(admin_id,'BINARY_REALTIME_DISTRIBUTED','binary_cycle',cycle,jsonb_build_object('pool',pool,'shares',share_count,'share_points_each_side',share_points,'share_price',p_manual_share_value));
 return cycle;
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb; cycle uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 d:=public.admin_binary_pool_dashboard();
 if coalesce((d->>'can_distribute')::boolean,false) is not true then raise exception 'No funded binary shares are ready'; end if;
 cycle:=public.admin_close_binary_cycle(d->>'next_cycle_code',(d->>'period_start')::timestamptz,clock_timestamp(),'Asia/Karachi',p_share_value);
 return jsonb_build_object('cycle_id',cycle,'cycle_code',d->>'next_cycle_code','share_price',p_share_value,'distributed_shares',d->>'total_shares');
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_price numeric,p_total_amount numeric)
returns jsonb language sql security definer set search_path='' as $$
 select public.admin_distribute_binary_pool(p_share_price)
$$;

notify pgrst,'reload schema';
