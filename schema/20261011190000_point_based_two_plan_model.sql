-- Final model: DP funds sponsor bonus and creates separate GP/BP plan bases.
alter table public.shopping_reward_events
 add column if not exists dp numeric(18,4),
 add column if not exists gp numeric(18,4),
 add column if not exists bp numeric(18,4);
update public.shopping_reward_events set dp=coalesce(dp,bv),gp=coalesce(gp,trunc(bv*.5,4)),bp=coalesce(bp,trunc(bv*.5,4));
alter table public.shopping_reward_events alter column dp set not null,alter column gp set not null,alter column bp set not null;
alter table public.shopping_reward_events add constraint shopping_reward_events_point_bases_nonnegative check(dp>=0 and gp>=0 and bp>=0);

do $$
declare cfg jsonb;v integer;plan_key text;level_count integer;rates jsonb;i integer;
begin
 select config_value into cfg from public.system_config where config_key='MLM_PLANS' and effective_to is null for update;
 v:=(cfg->>'version')::integer;
 cfg:=(cfg-'direct_generation_cap')||jsonb_build_object(
  'version',v+1,'generation_plan_rate',.50,'binary_plan_rate',.50,
  'generation_bonus_rate',.45,'generation_manager_rate',.05,'generation_global_rate',.20,
  'binary_pool_rate',.35,'single_line_cap',.10,'binary_manager_rate',.05,'binary_global_rate',.20,
  'shopping_dp_factor',1
 );
 for plan_key in select jsonb_object_keys(cfg->'plans') loop
  level_count:=(cfg->'plans'->plan_key->>'max_generations')::integer;rates:='{}'::jsonb;
  if level_count>=2 then for i in 2..level_count loop rates:=rates||jsonb_build_object(i::text,.05);end loop;end if;
  cfg:=jsonb_set(cfg,array['plans',plan_key,'generation_rates'],rates,true);
 end loop;
 update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
end$$;

create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,private.package_eligible(u.id) eligible
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*(cfg->'plans'->case when eligible then coalesce(private.current_package_code(member),'BASIC_1') else 'BASIC_1' end->>'direct_rate')::numeric
       else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=(plan->>'max_generations')::integer);
$$;

create or replace function private.mlm_candidates(member uuid,b numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric)
language sql stable security definer set search_path='' as $$
 select c.beneficiary,c.method,c.depth,c.nominal from private.mlm_point_candidates(member,b,b,cfg)c;
$$;

create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare total numeric;scale numeric;amount numeric;r record;p uuid;current_member uuid:=member;side text;d integer:=0;plan jsonb;rates jsonb;cum numeric;prev numeric;direct_paid numeric:=0;gen_paid numeric:=0;sl numeric:=0;slscale numeric:=1;
 dp_base numeric:=b;gp_base numeric:=trunc(b*.5,4);bp_base numeric:=trunc(b*.5,4);gen_cap numeric;placement_cap numeric;
begin
 if oid is not null then select s.dp,s.gp,s.bp into dp_base,gp_base,bp_base from public.shopping_reward_events s where s.order_id=oid;
 elsif aid is not null then select a.dp,a.gp,a.bp into dp_base,gp_base,bp_base from public.package_activations a where a.id=aid;end if;
 dp_base:=coalesce(dp_base,b);gp_base:=coalesce(gp_base,trunc(dp_base*coalesce((cfg->>'generation_plan_rate')::numeric,.5),4));bp_base:=coalesce(bp_base,trunc(dp_base*coalesce((cfg->>'binary_plan_rate')::numeric,.5),4));
 gen_cap:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);placement_cap:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);
 select coalesce(sum(nominal),0) into total from private.mlm_point_candidates(member,dp_base,gp_base,cfg) where method='generation';
 scale:=case when total>0 then least(1,gen_cap/total) else 0 end;
 for r in select * from private.mlm_point_candidates(member,dp_base,gp_base,cfg) order by depth loop
  if r.method='direct' then amount:=trunc(r.nominal,4);direct_paid:=direct_paid+amount;else amount:=trunc(r.nominal*scale,4);gen_paid:=gen_paid+amount;end if;
  perform private.post_network_bonus(oid,aid,r.beneficiary,r.method,r.depth,r.qualifying_base,r.nominal,amount,cfg);
 end loop;
 select coalesce(sum(bp_base*coalesce((cfg->'plans'->private.current_package_code(x.id)->'single_line_rates'->>(x.depth-1))::numeric,0)),0) into total from (
  with recursive chain(id,depth,path) as(
   select q.parent_id,1,array[member,q.parent_id] from public.binary_placements q where q.member_id=member and q.parent_id is not null
   union all select q.parent_id,c.depth+1,c.path||q.parent_id from chain c join public.binary_placements q on q.member_id=c.id where q.parent_id is not null and c.depth<1000 and not q.parent_id=any(c.path)
  )select * from chain
 )x where private.package_eligible(x.id) and x.depth<=coalesce((cfg->'plans'->private.current_package_code(x.id)->>'single_line_levels')::integer,0);
 slscale:=case when total>0 then least(1,placement_cap/total) else 0 end;
 loop
  select q.parent_id,q.side into p,side from public.binary_placements q where q.member_id=current_member;exit when p is null;d:=d+1;if d>1000 then raise exception 'Placement ancestry exceeds supported depth';end if;
  if oid is not null and trunc(bp_base,4)>0 and not exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=p) then
   insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(bp_base,4),side,oid,'credit','shopping-bp:'||oid||':'||p) on conflict(idempotency_key) do nothing;end if;
  plan:=cfg->'plans'->private.current_package_code(p);
  if private.package_eligible(p) and d<=coalesce((plan->>'single_line_levels')::integer,0) then
   rates:=plan->'single_line_rates';select coalesce(sum(value::numeric),0) into cum from jsonb_array_elements_text(rates) with ordinality where ordinality<=d;select coalesce(sum(value::numeric),0) into prev from jsonb_array_elements_text(rates) with ordinality where ordinality<d;
   amount:=case when slscale=1 then trunc(round(bp_base*cum,12),4)-trunc(round(bp_base*prev,12),4) else trunc(bp_base*coalesce((rates->>(d-1))::numeric,0)*slscale,4) end;
   amount:=least(amount,greatest(0,placement_cap-sl));perform private.post_network_bonus(oid,aid,p,'single_line',d,bp_base,bp_base*coalesce((rates->>(d-1))::numeric,0),amount,cfg);sl:=sl+amount;end if;
  current_member:=p;
 end loop;
 return jsonb_build_object('direct',direct_paid,'generation',gen_paid,'direct_generation',direct_paid+gen_paid,'single_line',sl,'dp',dp_base,'gp',gp_base,'bp',bp_base);
end$$;

create or replace function private.snapshot_mlm_rules() returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(new.bp*coalesce((new.rules_snapshot->>'binary_pool_rate')::numeric,.35),4) else 0 end;end if;
 return new;
end$$;

create or replace function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;ppv numeric;total numeric;funding numeric;r record;outcome jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 select * into o from public.orders where id=new.id for update;
 if o.status in('cancelled','returned') and o.rewards_credited_at is null then update public.ecommerce_rewards set status='cancelled' where order_id=o.id and status='pending_delivery';return new;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if o.reward_version=1 then o.reward_owner_id:=o.buyer_id;perform private.post_shopping_rewards(o.id);
 else
  select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards';
  if ppv*300>funding then raise exception 'Order rewards exceed verified funding';end if;
  if o.reward_mode='MIO' then
   for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop perform private.credit_ecommerce_reward(r.id);end loop;
   update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;
  else
   dp_base:=trunc(ppv*coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric,1),4);gp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric,.5),4);bp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric,.5),4);
   insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,dp,gp,bp,binary_reserve_mio) values(o.id,o.reward_owner_id,funding,ppv,dp_base,gp_base,bp_base,trunc(bp_base*coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric,.35),4)) on conflict do nothing;
   if found then outcome:=private.distribute_mlm_event(o.reward_owner_id,ppv,o.id,null,o.rules_snapshot);update public.shopping_reward_events set direct_generation_mio=(outcome->>'direct_generation')::numeric,single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;end if;
  end if;
 end if;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.reward_owner_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);perform private.sync_company_treasury();return new;
end$$;

create or replace function private.guard_bonus_funding() returns trigger language plpgsql security definer set search_path='' as $$
declare spent numeric;ceiling numeric;cfg jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='binary_pool_share' then select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then select s.dp,s.gp,s.bp,o.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else select a.dp,a.gp,a.bp,a.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;end if;
  if new.method='direct' then ceiling:=new.gross_amount;elsif new.method='generation' then ceiling:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);else ceiling:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);end if;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where status in('posted','pending') and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id)) and method=new.method;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling then raise exception 'Bonus would exceed its funded source budget';end if;return new;
end$$;

create or replace function public.admin_save_plan(p_code text,p_plan jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;rate numeric;tot numeric;key text;gplan numeric;bplan numeric;genbonus numeric;genmanager numeric;genglobal numeric;placement numeric;pool numeric;bmanager numeric;bglobal numeric;
begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;perform private.require_recent_totp();perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 foreach key in array array['generation_plan_rate','binary_plan_rate','generation_bonus_rate','generation_manager_rate','generation_global_rate','single_line_cap','binary_pool_rate','binary_manager_rate','binary_global_rate'] loop if jsonb_typeof(p_plan->key)<>'number' then raise exception 'Missing numeric budget: %',key;end if;end loop;
 gplan:=(p_plan->>'generation_plan_rate')::numeric;bplan:=(p_plan->>'binary_plan_rate')::numeric;genbonus:=(p_plan->>'generation_bonus_rate')::numeric;genmanager:=(p_plan->>'generation_manager_rate')::numeric;genglobal:=(p_plan->>'generation_global_rate')::numeric;placement:=(p_plan->>'single_line_cap')::numeric;pool:=(p_plan->>'binary_pool_rate')::numeric;bmanager:=(p_plan->>'binary_manager_rate')::numeric;bglobal:=(p_plan->>'binary_global_rate')::numeric;
 if least(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)<0 or greatest(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)>1 then raise exception 'All percentages must be between 0 and 100';end if;
 if abs(gplan+bplan-1)>.000000001 then raise exception 'Generation Plan and Binary Plan must total exactly 100 percent';end if;if genbonus+genmanager+genglobal>1.000000001 then raise exception 'Generation breakdown exceeds 100 percent of GP';end if;if placement+pool+bmanager+bglobal>1.000000001 then raise exception 'Binary breakdown exceeds 100 percent of BP';end if;
 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','company_fee','ppv','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','single_line_levels'] loop if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 then raise exception 'Invalid plan value: %',key;end if;end loop;
 if (p_plan->>'base_value')::numeric<=0 or (p_plan->>'ppv')::numeric<=0 or (p_plan->>'bv')::numeric>(p_plan->>'base_value')::numeric or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;if (p_plan->>'bv')::numeric>(p_plan->>'ppv')::numeric then raise exception 'BV cannot exceed PPV';end if;
 if abs((p_plan->>'gp')::numeric-(p_plan->>'dp')::numeric*gplan)>.0001 or abs((p_plan->>'bp')::numeric-(p_plan->>'dp')::numeric*bplan)>.0001 then raise exception 'GP and BP must follow the configured DP plan split';end if;
 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;if levels not between 1 and 10 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–10; binary placement limit 1–30';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 tot:=0;for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;tot:=tot+rate;end loop;if tot>genbonus+.000000001 then raise exception 'Generation levels exceed the Generation bonus budget';end if;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid binary placement rate';end if;tot:=tot+rate;end loop;if tot>placement+.000000001 then raise exception 'Binary placement levels exceed their budget';end if;
 cfg:=cfg||jsonb_build_object('generation_plan_rate',gplan,'binary_plan_rate',bplan,'generation_bonus_rate',genbonus,'generation_manager_rate',genmanager,'generation_global_rate',genglobal,'single_line_cap',placement,'binary_pool_rate',pool,'binary_manager_rate',bmanager,'binary_global_rate',bglobal);
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement) values(p_code,old.version+1,old.display_name,(p_plan->>'base_value')::numeric,(p_plan->>'company_fee')::numeric,(p_plan->>'ppv')::numeric,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels) into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'generation_plan',jsonb_build_object('split',gplan,'generation',genbonus,'manager',genmanager,'global',genglobal),'binary_plan',jsonb_build_object('split',bplan,'pool',pool,'placement',placement,'manager',bmanager,'global',bglobal)));
 return cfg;
end$$;

create or replace function private.company_treasury_sources_before_ecommerce() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 with funding as(
  select 'order'::text typ,s.order_id id,s.bv base,s.dp,s.gp,s.bp,s.binary_reserve_mio reserve,o.rules_snapshot cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.dp,a.gp,a.bp,a.binary_reserve_mio,a.rules_snapshot from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ),spend as(
  select f.*,coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='direct'),0) direct_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='generation'),0) gen_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='single_line'),0) placement_paid from funding f
 )
 select typ,id,'generation_levels_pending','MIO',greatest(0,trunc(gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4)-gen_paid) from spend
 union all select typ,id,'generation_manager_pending','MIO',trunc(gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'generation_global_pending','MIO',trunc(gp*coalesce((cfg->>'generation_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'binary_placement_pending','MIO',greatest(0,trunc(bp*coalesce((cfg->>'single_line_cap')::numeric,.10),4)-placement_paid) from spend
 union all select typ,id,'binary_pool_pending','MIO',reserve from spend
 union all select typ,id,'binary_manager_pending','MIO',trunc(bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'binary_global_pending','MIO',trunc(bp*coalesce((cfg->>'binary_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'network_formula_leftover','MIO',greatest(0,dp-gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45)-gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05)-gp*coalesce((cfg->>'generation_global_rate')::numeric,.20)-bp*coalesce((cfg->>'binary_pool_rate')::numeric,.35)-bp*coalesce((cfg->>'single_line_cap')::numeric,.10)-bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05)-bp*coalesce((cfg->>'binary_global_rate')::numeric,.20)-direct_paid) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*300) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$$;

revoke all on function private.mlm_point_candidates(uuid,numeric,numeric,jsonb) from public,anon,authenticated;
revoke all on function private.mlm_candidates(uuid,numeric,jsonb),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb),private.snapshot_mlm_rules(),private.release_order_rewards(),private.guard_bonus_funding(),private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
grant execute on function public.admin_save_plan(text,jsonb,integer) to authenticated;
