-- Master-editable reward budgets. Each event keeps the rules version captured when it was created.
alter table public.binary_cycles drop constraint if exists binary_cycles_pool_rate_check;
alter table public.binary_cycles add constraint binary_cycles_pool_rate_check check(pool_rate between 0 and 1);

-- Shopping reward records may follow any safely configured split whose total fits its funded BV.
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_direct_generation_mio_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_single_line_mio_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_binary_reserve_mio_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_check1;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_check2;
alter table public.shopping_reward_events add constraint shopping_reward_events_budget_nonnegative check(direct_generation_mio>=0 and single_line_mio>=0 and binary_reserve_mio>=0);
alter table public.shopping_reward_events add constraint shopping_reward_events_budget_within_bv check(direct_generation_mio+single_line_mio+binary_reserve_mio<=bv);

-- Preserve the existing master/TOTP and optimistic version checks while adding budget inputs.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_save_plan(text,jsonb,integer)'::regprocedure);
 f:=replace(f,'key text;begin','key text;dg_cap numeric;sl_cap numeric;binary_rate numeric;begin');
 if position('dg_cap numeric' in f)=0 then raise exception 'Could not extend admin_save_plan declarations';end if;
 f:=replace(f,
  $old$if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;$old$,
  $new$if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 if (p_plan ? 'direct_generation_cap' and jsonb_typeof(p_plan->'direct_generation_cap')<>'number') or (p_plan ? 'single_line_cap' and jsonb_typeof(p_plan->'single_line_cap')<>'number') or (p_plan ? 'binary_pool_rate' and jsonb_typeof(p_plan->'binary_pool_rate')<>'number') then raise exception 'Distribution budget inputs must be numeric';end if;
 dg_cap:=coalesce((p_plan->>'direct_generation_cap')::numeric,(cfg->>'direct_generation_cap')::numeric,.55);sl_cap:=coalesce((p_plan->>'single_line_cap')::numeric,(cfg->>'single_line_cap')::numeric,.10);binary_rate:=coalesce((p_plan->>'binary_pool_rate')::numeric,(cfg->>'binary_pool_rate')::numeric,.35);
 if dg_cap<0 or sl_cap<0 or binary_rate<0 or dg_cap>1 or sl_cap>1 or binary_rate>1 or dg_cap+sl_cap+binary_rate>1.000000000001 then raise exception 'Distribution budgets must each be between 0 and 100 percent and total no more than 100 percent';end if;
 cfg:=jsonb_set(jsonb_set(jsonb_set(cfg,'{direct_generation_cap}',to_jsonb(dg_cap),true),'{single_line_cap}',to_jsonb(sl_cap),true),'{binary_pool_rate}',to_jsonb(binary_rate),true);$new$);
 if position('dg_cap:=coalesce((p_plan' in f)=0 then raise exception 'Could not add distribution budget validation';end if;
 f:=replace(f,'if tot>.100000000001 then raise exception ''Single-line total cannot exceed the funded 10 percent budget'';end if;',
  'if tot>sl_cap+0.000000000001 then raise exception ''Single-line total cannot exceed the configured budget'';end if;');
 if position('tot>sl_cap' in f)=0 then raise exception 'Could not make single-line validation configurable';end if;
 f:=replace(f,$old$jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan)$old$,$new$jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'direct_generation_cap',dg_cap,'single_line_cap',sl_cap,'binary_pool_rate',binary_rate)$new$);
 execute f;
end $$;

-- Capture the selected binary share on new package activations; orders keep the full rules snapshot as before.
create or replace function private.snapshot_mlm_rules() returns trigger language plpgsql security definer set search_path='' as $$begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then
  new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(least(new.bv,new.base_value,new.payable_price-new.company_fee)*coalesce((new.rules_snapshot->>'binary_pool_rate')::numeric,.35),4) else 0 end;
 end if;
 return new;
end $$;

-- Direct/generation and single-line caps are read from the event's immutable snapshot.
do $$declare f text;begin
 f:=pg_get_functiondef('private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb)'::regprocedure);
 f:=replace(f,'trunc(b*.55,4)','trunc(b*coalesce((cfg->>''direct_generation_cap'')::numeric,.55),4)');
 f:=replace(f,'trunc(b*.10,4)','trunc(b*coalesce((cfg->>''single_line_cap'')::numeric,.10),4)');
 if position('cfg->>''direct_generation_cap''' in f)=0 or position('cfg->>''single_line_cap''' in f)=0 then raise exception 'Could not make MLM event caps configurable';end if;
 execute f;
end $$;

-- Protect all bonus writers against the configured source-event cap, including package activations.
create or replace function private.guard_bonus_funding() returns trigger language plpgsql security definer set search_path='' as $$
declare b numeric;spent numeric;ceiling numeric;cfg jsonb;begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then
   select s.bv,o.rules_snapshot into b,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else
   select least(a.bv,a.base_value,a.payable_price-a.company_fee),a.rules_snapshot into b,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;
  end if;
  ceiling:=trunc(b*case when new.method='single_line' then coalesce((cfg->>'single_line_cap')::numeric,.10) else coalesce((cfg->>'direct_generation_cap')::numeric,.55) end,4);
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where status in('posted','pending') and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id)) and case when new.method='single_line' then method='single_line' else method in('direct','generation') end;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling then raise exception 'Bonus would exceed its funded source budget';end if;return new;
end $$;

-- E-commerce PPV mode reserves the configured binary share for the same source event.
do $$declare f text;begin
 f:=pg_get_functiondef('private.release_order_rewards()'::regprocedure);
 f:=replace(f,'trunc(ppv*.35,4)','trunc(ppv*coalesce((o.rules_snapshot->>''binary_pool_rate'')::numeric,.35),4)');
 if position('o.rules_snapshot->>''binary_pool_rate''' in f)=0 then raise exception 'Could not make order binary reserve configurable';end if;
 execute f;
end $$;

-- A cycle contains event-level reserves (which can have different historical rates).
-- Store its effective aggregate rate while distributing the exact reserved pool.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_close_binary_cycle(text,timestamptz,timestamptz,text)'::regprocedure);
 f:=replace(f,'eligible numeric; pool numeric;','eligible numeric; pool numeric; effective_rate numeric;');
 if position('effective_rate numeric' in f)=0 then raise exception 'Could not add binary effective rate';end if;
 f:=replace(f,'eligible:=eligible+(select coalesce(sum(bv),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);',
  'eligible:=eligible+(select coalesce(sum(bv),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);'||chr(10)||
  ' effective_rate:=case when eligible>0 then pool/eligible else coalesce((private.current_mlm_rules()->>''binary_pool_rate'')::numeric,.35) end;');
 f:=replace(f,'eligible,p_timezone,p_timezone','eligible,p_timezone,p_timezone');
 f:=replace(f,'p_timezone,eligible,0.35,pool','p_timezone,eligible,effective_rate,pool');
 f:=replace(f,$old$'pool_rate',0.35$old$,$new$'pool_rate',effective_rate$new$);
 if position('effective_rate:=case' in f)=0 or position('eligible,effective_rate,pool' in f)=0 then raise exception 'Could not make binary cycle rate configurable';end if;
 execute f;
end $$;

-- Company pending budgets use the same rates saved with each package/order event.
create or replace function private.company_treasury_sources_before_ecommerce() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 with funding as(
  select 'order'::text typ,s.order_id id,s.bv base,s.binary_reserve_mio reserve,
   coalesce((o.rules_snapshot->>'direct_generation_cap')::numeric,.55) dg_cap,coalesce((o.rules_snapshot->>'single_line_cap')::numeric,.10) sl_cap
  from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all
  select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.binary_reserve_mio,
   coalesce((a.rules_snapshot->>'direct_generation_cap')::numeric,.55),coalesce((a.rules_snapshot->>'single_line_cap')::numeric,.10)
  from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ), spend as(
  select f.*,coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status in('posted','pending') and ((f.typ='order' and b.source_order_id=f.id) or (f.typ='package' and b.source_activation_id=f.id)) and b.method in('direct','generation')),0) dg,
   coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status in('posted','pending') and ((f.typ='order' and b.source_order_id=f.id) or (f.typ='package' and b.source_activation_id=f.id)) and b.method='single_line'),0) sl
  from funding f
 )
 select typ,id,'direct_generation_leftover','MIO',greatest(0,trunc(base*dg_cap,4)-dg) from spend
 union all select typ,id,'single_line_leftover','MIO',greatest(0,trunc(base*sl_cap,4)-sl) from spend
 union all select typ,id,'network_rounding_leftover','MIO',greatest(0,base-trunc(base*dg_cap,4)-trunc(base*sl_cap,4)-reserve) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*300) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$$;
revoke all on function private.snapshot_mlm_rules(),private.guard_bonus_funding(),private.release_order_rewards(),private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
notify pgrst,'reload schema';
