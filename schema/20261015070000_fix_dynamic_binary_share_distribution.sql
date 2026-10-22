-- Remove the obsolete fixed 50-BP settlement check. The active BP/share rule
-- is versioned in MLM_PLANS and is recorded in each result snapshot.
alter table public.binary_member_results
  drop constraint if exists binary_member_results_check1;

alter table public.binary_member_results
  add constraint binary_member_results_consumption_check
  check (
    consumed_left = consumed_right
    and consumed_left >= 0
    and consumed_left <= left_available
    and consumed_right <= right_available
    and carry_left = left_available - consumed_left
    and carry_right = right_available - consumed_right
  );

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare cutoff timestamptz:=private.financial_reset_at();pend timestamptz:=clock_timestamp();pstart timestamptz;cycle uuid:=gen_random_uuid();code text;wallet numeric:=0;shares numeric:=0;pool numeric:=0;m record;gross numeric;pay numeric;txn uuid;k text;
begin
 if auth.uid()is null or not private.has_role('admin')then raise exception 'Admin access required';end if;
 if p_share_value is null or p_share_value<=0 then raise exception 'Enter a share price greater than zero';end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 select coalesce(max(ends_at),cutoff)into pstart from public.binary_cycles where status in('posted','unallocated')and created_at>cutoff;
 select greatest(0,coalesce((select sum(binary_reserve_mio)from public.package_activations where status='approved'and source<>'SHOPPING_PPV'and coalesce(activated_at,requested_at)>cutoff),0)+coalesce((select sum(binary_reserve_mio)from public.shopping_reward_events where created_at>cutoff),0)-coalesce((select sum(pool_amount)from public.binary_cycles where status in('posted','unallocated')and created_at>cutoff),0))into wallet;
 select coalesce(sum(completed_shares),0)into shares from private.binary_live_shares(pend);
 if shares<=0 then raise exception 'No payable binary shares are available';end if;
 pool:=trunc(p_share_value*shares,4);
 if pool>wallet+.00000001 then raise exception 'Share price exceeds current binary pool wallet';end if;
 code:='REALTIME-'||to_char(pend at time zone 'Asia/Karachi','YYYYMMDD-HH24MISS-MS');
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,total_completed_shares,gross_share_value,status)values(cycle,code,pstart,pend,'Asia/Karachi',0,0,pool,shares,p_share_value,'frozen');
 for m in select * from private.binary_live_shares(pend)where completed_shares>0 order by member_id loop
  gross:=trunc(p_share_value*m.completed_shares,4);pay:=trunc(gross*m.binary_entitlement,4);
  insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)values(cycle,m.member_id,m.package_code,m.package_version,m.left_available,m.right_available,m.completed_shares,m.binary_entitlement,gross,pay,gross-pay,m.consumed_each,m.consumed_each,m.left_available-m.consumed_each,m.right_available-m.consumed_each,jsonb_build_object('qualification','realtime_fractional_share','share_increment',.1,'share_price',p_share_value,'package_entitlement_snapshot',m.binary_entitlement,'lifetime_bp_preserved',true));
  if pay>0 then
   k:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)values(m.member_id,'binary_pool_share',cycle,gross,m.binary_entitlement,gross,pay,'MIO','realtime-binary-pool-v3',jsonb_build_object('completed_shares',m.completed_shares,'share_price',p_share_value,'package_entitlement_snapshot',m.binary_entitlement,'consumed_each_side',m.consumed_each,'pool_before',wallet,'pool_after',wallet-pool,'company_retention',gross-pay),'posted',k)returning id into txn;
   update public.mio_wallet_accounts set balance=balance+pay,updated_at=now()where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing';end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)values(m.member_id,pay,'bonus_credit',txn,cycle,'Real-time Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 update public.binary_cycles set status='posted',closed_at=clock_timestamp()where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)values(auth.uid(),'BINARY_REALTIME_DISTRIBUTED','binary_cycle',cycle,jsonb_build_object('pool_before',wallet,'distributed_pool',pool,'pool_after',wallet-pool,'shares',shares,'share_price',p_share_value));
 return jsonb_build_object('cycle_id',cycle,'cycle_code',code,'share_price',p_share_value,'distributed_shares',shares,'distributed_amount',pool,'remaining_pool',wallet-pool);
end$$;

notify pgrst,'reload schema';
