-- Manual weekly Binary Pool Share settlement.
-- Automatic settlement is disabled; admins preview the week, enter the gross
-- value per completed share, and distribute after the seven-day period closes.

create or replace function public.admin_close_binary_cycle(
  p_cycle_code text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_manual_share_value numeric default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cycle uuid:=gen_random_uuid(); eligible numeric:=0; reserved_pool numeric:=0; pool numeric:=0; effective_rate numeric:=0;
 share_count bigint:=0; m record; gross numeric; member_pay numeric; remainder numeric; residual_recipient uuid; txn uuid; key text;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at or p_ends_at>now() then raise exception 'Choose a completed period with valid start/end'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
 if p_ends_at-p_starts_at<interval '7 days' then raise exception 'Binary pool can be distributed only after seven days'; end if;
 if p_manual_share_value is not null and p_manual_share_value<0 then raise exception 'Share value cannot be negative'; end if;
 if exists(select 1 from public.binary_cycles where status<>'reversed' and starts_at<p_ends_at and ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated') and ends_at>p_starts_at) then raise exception 'Close binary cycles in chronological order'; end if;
 if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated')) and p_starts_at<>(select max(ends_at) from public.binary_cycles where status in ('posted','unallocated')) then raise exception 'Start the cycle at the previous cycle end'; end if;
 select coalesce(sum(least(a.base_value,a.bv,a.payable_price-a.company_fee)),0),coalesce(sum(a.binary_reserve_mio),0) into eligible,reserved_pool
 from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at;
 eligible:=eligible+(select coalesce(sum(s.bv),0) from public.shopping_reward_events s where s.created_at>=p_starts_at and s.created_at<p_ends_at);
 reserved_pool:=reserved_pool+(select coalesce(sum(s.binary_reserve_mio),0) from public.shopping_reward_events s where s.created_at>=p_starts_at and s.created_at<p_ends_at);
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
 values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,p_timezone,eligible,case when eligible>0 then reserved_pool/eligible else coalesce((private.current_mlm_rules()->>'binary_pool_rate')::numeric,.35) end,0,'open');
 for m in
  with active_package as (
   select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,coalesce((private.current_mlm_rules()->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
   from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
   where a.status='approved' and a.activated_at<p_ends_at
   order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
  ), volume as (
   select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
   from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id
   where pl.point_type='BP' and ((a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at<p_ends_at) or s.created_at<p_ends_at) and pl.created_at<=now()
   group by pl.member_id
  ), consumed as (
   select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
   where c.status in ('posted','unallocated') and c.ends_at<=p_starts_at group by r.member_id
  )
  select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) l,greatest(coalesce(v.r,0)-coalesce(c.r,0),0) r
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 loop
  insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)
  values(cycle,m.member_id,m.package_code,m.package_version,m.l,m.r,floor(least(m.l,m.r)/50)::bigint,m.binary_entitlement,0,0,0,floor(least(m.l,m.r)/50)*50,floor(least(m.l,m.r)/50)*50,m.l-floor(least(m.l,m.r)/50)*50,m.r-floor(least(m.l,m.r)/50)*50,jsonb_build_object('qualification','active_package_and_full_share','reserved_pool',reserved_pool,'share_points_each_side',50,'manual_share_value',p_manual_share_value,'precision',4));
 end loop;
 select coalesce(sum(completed_shares),0) into share_count from public.binary_member_results where cycle_id=cycle;
 if share_count=0 then
  update public.binary_cycles set status='unallocated',pool_amount=0,total_completed_shares=0,closed_at=now() where id=cycle;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'reserved_pool',reserved_pool,'shares',0));
  return cycle;
 end if;
 pool:=case when p_manual_share_value is null then reserved_pool else trunc(p_manual_share_value*share_count,4) end;
 if pool>reserved_pool+.00000001 then raise exception 'Share value exceeds current binary pool wallet'; end if;
 effective_rate:=case when eligible>0 then pool/eligible else coalesce((private.current_mlm_rules()->>'binary_pool_rate')::numeric,.35) end;
 update public.binary_cycles set pool_amount=pool,pool_rate=effective_rate,total_completed_shares=share_count,gross_share_value=pool/share_count,status='frozen' where id=cycle;
 update public.binary_member_results set gross_amount=trunc(pool*completed_shares/share_count,4),company_retention=trunc(pool*completed_shares/share_count,4) where cycle_id=cycle;
 select pool-coalesce(sum(gross_amount),0) into remainder from public.binary_member_results where cycle_id=cycle;
 for residual_recipient in select member_id from public.binary_member_results where cycle_id=cycle and completed_shares>0 order by (pool*completed_shares/share_count-trunc(pool*completed_shares/share_count,4)) desc,member_id limit round(remainder*10000)::integer
 loop
  update public.binary_member_results set gross_amount=gross_amount+0.0001,company_retention=company_retention+0.0001 where cycle_id=cycle and member_id=residual_recipient;
 end loop;
 for m in select * from public.binary_member_results where cycle_id=cycle order by member_id loop
  gross:=m.gross_amount; member_pay:=trunc(gross*m.entitlement,4);
  update public.binary_member_results set member_amount=member_pay,company_retention=gross-member_pay where cycle_id=cycle and member_id=m.member_id;
  if member_pay>0 then
   key:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
   values(m.member_id,'binary_pool_share',cycle,gross,m.entitlement,gross,member_pay,'MIO','phase1-binary-pool-manual-v1',jsonb_build_object('completed_shares',m.completed_shares,'entitlement',m.entitlement,'gross_share_value',pool/share_count,'manual_share_value',p_manual_share_value,'member_amount',member_pay,'company_retention',gross-member_pay,'rounding','largest_remainder_4dp'),'posted',key) returning id into txn;
   update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing'; end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key) values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 if (select coalesce(sum(member_amount+company_retention),0) from public.binary_member_results where cycle_id=cycle)<>pool then raise exception 'Pool reconciliation failed'; end if;
 update public.binary_cycles set status='posted',closed_at=now() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'reserved_pool',reserved_pool,'pool',pool,'shares',share_count,'manual_share_value',p_manual_share_value,'rounding','largest_remainder_4dp'));
 return cycle;
end;
$$;

create or replace function public.admin_close_binary_cycle(p_cycle_code text,p_starts_at timestamptz,p_ends_at timestamptz,p_timezone text)
returns uuid language sql security definer set search_path='' as $$select public.admin_close_binary_cycle(p_cycle_code,p_starts_at,p_ends_at,p_timezone,null::numeric)$$;

create or replace function public.admin_binary_pool_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
declare admin_id uuid:=auth.uid(); earliest_event timestamptz; last_end timestamptz; period_start timestamptz; period_end timestamptz; total_wallet numeric:=0; week_pool numeric:=0; last_distributed numeric:=0; total_shares bigint:=0; package_json jsonb:='[]'::jsonb;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 select min(event_at) into earliest_event from(select a.activated_at event_at from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' union all select s.created_at from public.shopping_reward_events s) events;
 select max(ends_at) into last_end from public.binary_cycles where status in('posted','unallocated');
 period_start:=coalesce(last_end,date_trunc('week',coalesce(earliest_event,now()) at time zone 'Asia/Karachi') at time zone 'Asia/Karachi');
 period_end:=period_start+interval '7 days';
 select greatest(0,coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV'),0)+coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events),0)-coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated')),0)) into total_wallet;
 select coalesce(sum(binary_reserve_mio),0) into week_pool from(select a.binary_reserve_mio from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>=period_start and a.activated_at<period_end union all select s.binary_reserve_mio from public.shopping_reward_events s where s.created_at>=period_start and s.created_at<period_end) x;
 with active_package as (
  select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,coalesce((private.current_mlm_rules()->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
  from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
  where a.status='approved' and a.activated_at<period_end
  order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
 ), volume as (
  select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
  from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id
  where pl.point_type='BP' and ((a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at<period_end) or s.created_at<period_end) and pl.created_at<=now()
  group by pl.member_id
 ), consumed as (
  select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where c.status in('posted','unallocated') and c.ends_at<=period_start group by r.member_id
 ), shares as (
  select ap.package_code,floor(least(greatest(coalesce(v.l,0)-coalesce(c.l,0),0),greatest(coalesce(v.r,0)-coalesce(c.r,0),0))/50)::bigint completed from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 )
 select coalesce(sum(shares),0),coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb) into total_shares,package_json from (select package_code,sum(completed) shares from shares group by package_code having sum(completed)>0) p;
 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles where status='posted' order by ends_at desc limit 1;
 return jsonb_build_object('total_pool_wallet',total_wallet,'this_week_pool',week_pool,'last_week_distributed',last_distributed,'total_shares',coalesce(total_shares,0),'shares_by_package',package_json,'period_start',period_start,'period_end',period_end,'can_distribute',period_end<=now() and coalesce(total_shares,0)>0 and week_pool>0,'default_share_value',case when coalesce(total_shares,0)>0 then trunc(week_pool/total_shares,4) else 0 end,'next_cycle_code','MANUAL-'||to_char(period_start at time zone 'Asia/Karachi','IYYY-"W"IW'));
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb; cycle uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 d:=public.admin_binary_pool_dashboard();
 if coalesce((d->>'can_distribute')::boolean,false) is not true then raise exception 'Binary pool is not ready for distribution yet'; end if;
 cycle:=public.admin_close_binary_cycle(d->>'next_cycle_code',(d->>'period_start')::timestamptz,(d->>'period_end')::timestamptz,'Asia/Karachi',p_share_value);
 return jsonb_build_object('cycle_id',cycle,'cycle_code',d->>'next_cycle_code','share_value',p_share_value);
end;
$$;

create or replace function private.run_automatic_binary_pool()
returns integer language plpgsql security definer set search_path='' as $$begin return 0; end$$;

do $$begin
 if to_regclass('cron.job') is not null then
  perform cron.unschedule(jobid) from cron.job where jobname='mio-automatic-binary-pool';
 end if;
exception when others then null;
end$$;

revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) from public,anon;
revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text,numeric) from public,anon;
revoke all on function public.admin_binary_pool_dashboard() from public,anon;
revoke all on function public.admin_distribute_binary_pool(numeric) from public,anon;
grant execute on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.admin_binary_pool_dashboard() to authenticated;
grant execute on function public.admin_distribute_binary_pool(numeric) to authenticated;
revoke all on function private.run_automatic_binary_pool() from public,anon,authenticated;
notify pgrst,'reload schema';
