-- Approved simulation defaults; immutable snapshots for future events.
alter table public.orders add column rules_snapshot jsonb not null default '{}'::jsonb;
alter table public.package_activations add column rules_snapshot jsonb not null default '{}'::jsonb, add column binary_reserve_mio numeric(18,4) not null default 0;
update public.package_activations set binary_reserve_mio=trunc(least(bv,base_value,payable_price-company_fee)*.35,4) where status='approved' and source<>'SHOPPING_PPV';
insert into public.system_config(config_key,version,config_value)
select 'MLM_PLANS',1,jsonb_build_object('version',1,'direct_generation_cap',.55,'single_line_cap',.10,'binary_pool_rate',.35,'shopping_ppv_factor',.90,'shopping_bp_factor',.50,'pkr_per_mio',300,'plans',jsonb_object_agg(p.package_code,to_jsonb(p)||jsonb_build_object('generation_rates',(select jsonb_object_agg(n::text,.05) from generate_series(2,p.max_generations)n),'single_line_levels',case p.package_code when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 else 30 end,'single_line_rates',(select jsonb_agg(1::numeric/300) from generate_series(1,case p.package_code when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 else 30 end))))) from public.package_versions p where is_active;
create function private.current_mlm_rules() returns jsonb language sql stable security definer set search_path='' as $$select config_value from public.system_config where config_key='MLM_PLANS' and effective_to is null order by version desc limit 1$$;
create function public.get_plan_catalog() returns jsonb language sql stable security definer set search_path='' as $$select private.current_mlm_rules()$$;
create function private.snapshot_mlm_rules() returns trigger language plpgsql security definer set search_path='' as $$begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(least(new.bv,new.base_value,new.payable_price-new.company_fee)*.35,4) else 0 end;end if;
 return new;
end $$;
create trigger a_snapshot_mlm_rules before insert on public.orders for each row execute function private.snapshot_mlm_rules();
create trigger a_snapshot_mlm_rules before insert on public.package_activations for each row execute function private.snapshot_mlm_rules();
create function public.admin_save_plan(p_code text,p_plan jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;rate numeric;tot numeric;key text;begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;perform private.require_recent_totp();
 perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;
 if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','company_fee','ppv','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','single_line_levels'] loop
  if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;
  rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 or rate<>round(rate,case when key in('direct_rate','binary_entitlement') then 6 when key in('base_value','company_fee') then 2 else 4 end) then raise exception 'Invalid plan value: %',key;end if;
 end loop;
 if (p_plan->>'base_value')::numeric<=0 or (p_plan->>'ppv')::numeric<=0 or (p_plan->>'bv')::numeric>(p_plan->>'base_value')::numeric or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;
 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;
 if levels not between 1 and 10 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–10; single-line limit 1–30';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' or not((p_plan->'generation_rates') ? i::text) then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;end loop;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid single-line rate';end if;tot:=tot+rate;end loop;
 if tot>.100000000001 then raise exception 'Single-line total cannot exceed the funded 10 percent budget';end if;
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement)
 values(p_code,old.version+1,old.display_name,(p_plan->>'base_value')::numeric,(p_plan->>'company_fee')::numeric,(p_plan->>'ppv')::numeric,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels) into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));
 update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan));
 return cfg;
end $$;
-- Inactive registration allows referrals; incentive eligibility is separate.
create function private.registered_member(member uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.member_profiles where user_id=member and status in('active','inactive') and terms_accepted_at is not null)$$;
create or replace function private.enforce_package_membership() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.sponsor_id is not null and (TG_OP='INSERT' or new.sponsor_id is distinct from old.sponsor_id) and not private.registered_member(new.sponsor_id) and not exists(select 1 from public.user_roles where user_id=new.sponsor_id and role='admin') then raise exception 'Registered sponsor required';end if;
 if new.status='active' and not exists(select 1 from public.user_roles where user_id=new.user_id and role='admin') and not exists(select 1 from public.package_activations where member_id=new.user_id and status='approved') then new.status:='inactive';end if;return new;
end $$;
do $$declare f text;sig text;begin
 foreach sig in array array['private.create_member_profile()','private.complete_referral_join(text,text,text,boolean)','public.lookup_side_referral(text)'] loop
 f:=pg_get_functiondef(sig::regprocedure);f:=replace(f,'and status=''active''','and status in(''active'',''inactive'') and terms_accepted_at is not null');f:=replace(f,'and m.status=''active''','and m.status in(''active'',''inactive'') and m.terms_accepted_at is not null');execute f;end loop;
end $$;
create or replace function private.enforce_bonus_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.payable_amount<=0 or new.status='reversed' then return new;end if;
 if new.source_order_id is not null then select buyer_id into buyer from public.orders where id=new.source_order_id;elsif new.source_activation_id is not null then select member_id into buyer from public.package_activations where id=new.source_activation_id;end if;
 if buyer=new.beneficiary_id then raise exception 'Own purchase gives PPV only';end if;
 if not private.package_eligible(new.beneficiary_id) then
 if new.method<>'direct' or not private.registered_member(new.beneficiary_id) or coalesce(new.generation,1)<>1 then raise exception 'Inactive member can earn held direct level only';end if;new.status:='pending';end if;return new;
end $$;
create function private.release_direct_holds() returns trigger language plpgsql security definer set search_path='' as $$declare b record;begin
 if new.status<>'approved' or not private.package_eligible(new.member_id) then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended('release-holds:'||new.member_id::text,0));
 for b in update public.bonus_transactions set status='posted' where beneficiary_id=new.member_id and method='direct' and status='pending' returning * loop
 insert into public.mio_ledger(member_id,amount,action,source_order_id,activation_id,bonus_transaction_id,reason,idempotency_key) values(new.member_id,b.payable_amount,'bonus_credit',b.source_order_id,b.source_activation_id,b.id,'Released held direct earning','bonus:'||b.id) on conflict(idempotency_key) do nothing;
 if found then update public.mio_wallet_accounts set balance=balance+b.payable_amount,updated_at=now() where member_id=new.member_id;end if;
 end loop;return new;
end $$;
create trigger ab_release_direct_holds after insert or update of status on public.package_activations for each row execute function private.release_direct_holds();
create function private.mlm_candidates(member uuid,b numeric,cfg jsonb) returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric) language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)),
 resolved as(select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,private.package_eligible(u.id) eligible from up u where depth>0 and private.registered_member(u.id))
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
 b*case when depth=1 then (cfg->'plans'->case when eligible then coalesce(private.current_package_code(member),'BASIC_1') else 'BASIC_1' end->>'direct_rate')::numeric else coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=(plan->>'max_generations')::integer);
$$;
create function private.post_network_bonus(oid uuid,aid uuid,who uuid,kind public.bonus_method,d integer,b numeric,nominal numeric,amount numeric,cfg jsonb) returns void language plpgsql security definer set search_path='' as $$declare tx uuid;state text;begin
 if amount<=0 then return;end if;
 insert into public.bonus_transactions(beneficiary_id,method,source_order_id,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
 values(who,kind,oid,aid,d,b,case when b>0 then amount/b else 0 end,nominal,amount,'MIO','editable-plans-v1',jsonb_build_object('plan_rules',cfg,'nominal_mio',nominal,'funded_mio',amount,'depth',d),'mlm:'||coalesce(oid,aid)||':'||kind||':'||who||':'||d) on conflict(idempotency_key) do nothing returning id,status into tx,state;
 if tx is not null and state='posted' then
 update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=who;if not found then raise exception 'Recipient wallet missing';end if;
 insert into public.mio_ledger(member_id,amount,action,source_order_id,activation_id,bonus_transaction_id,reason,idempotency_key) values(who,amount,'bonus_credit',oid,aid,tx,'Plan network bonus','bonus:'||tx);
 end if;
end $$;
create function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare total numeric;scale numeric;amount numeric;r record;p uuid;current_member uuid:=member;side text;d integer:=0;plan jsonb;rates jsonb;cum numeric;prev numeric;dg numeric:=0;sl numeric:=0;slscale numeric:=1;begin
 select coalesce(sum(nominal),0) into total from private.mlm_candidates(member,b,cfg);scale:=case when total>0 then least(1,trunc(b*.55,4)/total) else 0 end;
 select coalesce(sum(b*coalesce((cfg->'plans'->private.current_package_code(x.id)->'single_line_rates'->>(x.depth-1))::numeric,0)),0) into total from (
 with recursive chain(id,depth,path) as(select p.parent_id,1,array[member,p.parent_id] from public.binary_placements p where p.member_id=member and p.parent_id is not null union all select p.parent_id,c.depth+1,c.path||p.parent_id from chain c join public.binary_placements p on p.member_id=c.id where p.parent_id is not null and c.depth<1000 and not p.parent_id=any(c.path)) select * from chain
 )x where private.package_eligible(x.id) and x.depth<=coalesce((cfg->'plans'->private.current_package_code(x.id)->>'single_line_levels')::integer,0);
 slscale:=case when total>0 then least(1,trunc(b*.10,4)/total) else 0 end;
 for r in select * from private.mlm_candidates(member,b,cfg) order by depth loop
 amount:=trunc(r.nominal*scale,4);perform private.post_network_bonus(oid,aid,r.beneficiary,r.method,r.depth,b,r.nominal,amount,cfg);dg:=dg+amount;end loop;
 loop
 select bp.parent_id,bp.side into p,side from public.binary_placements bp where bp.member_id=current_member;exit when p is null;d:=d+1;if d>1000 then raise exception 'Placement ancestry exceeds supported depth';end if;
 if oid is not null and trunc(b*.5,4)>0 then insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(b*.5,4),side,oid,'credit','shopping-bp:'||oid||':'||p) on conflict(idempotency_key) do nothing;end if;
 plan:=cfg->'plans'->private.current_package_code(p);
 if private.package_eligible(p) and d<=coalesce((plan->>'single_line_levels')::integer,0) then
 rates:=plan->'single_line_rates';select coalesce(sum(value::numeric),0) into cum from jsonb_array_elements_text(rates) with ordinality where ordinality<=d;select coalesce(sum(value::numeric),0) into prev from jsonb_array_elements_text(rates) with ordinality where ordinality<d;
 amount:=case when slscale=1 then trunc(round(b*cum,12),4)-trunc(round(b*prev,12),4) else trunc(b*coalesce((rates->>(d-1))::numeric,0)*slscale,4) end;amount:=least(amount,greatest(0,trunc(b*.10,4)-sl));perform private.post_network_bonus(oid,aid,p,'single_line',d,b,b*coalesce((rates->>(d-1))::numeric,0),amount,cfg);sl:=sl+amount;end if;
 current_member:=p;
 end loop;return jsonb_build_object('direct_generation',dg,'single_line',sl);
end $$;
-- Keep legacy branches for pre-migration snapshots; new events use configured levels.
alter function private.credit_activation_bonuses(uuid) rename to credit_activation_bonuses_legacy;
create function private.credit_activation_bonuses(p_activation_id uuid) returns integer language plpgsql security definer set search_path='' as $$declare a public.package_activations%rowtype;r jsonb;begin
 select * into a from public.package_activations where id=p_activation_id;if a.id is null or a.status<>'approved' or a.source='SHOPPING_PPV' then return 0;end if;
 if a.rules_snapshot='{}'::jsonb then return private.credit_activation_bonuses_legacy(p_activation_id);end if;
 if exists(select 1 from public.bonus_transactions where source_activation_id=a.id and formula_version<>'editable-plans-v1') then return 0;end if;
 r:=private.distribute_mlm_event(a.member_id,least(a.bv,a.base_value,a.payable_price-a.company_fee),null,a.id,a.rules_snapshot);return 1;
end $$;
alter function private.credit_single_line(uuid) rename to credit_single_line_legacy;
create function private.credit_single_line(p_activation uuid) returns void language plpgsql security definer set search_path='' as $$declare a public.package_activations%rowtype;begin
 select * into a from public.package_activations where id=p_activation;
 if a.rules_snapshot='{}'::jsonb then perform private.credit_single_line_legacy(p_activation);end if;
 -- New activation's combined engine has already posted single-line exactly once.
end $$;
alter function private.post_shopping_rewards(uuid) rename to post_shopping_rewards_legacy;
create function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$declare buyer uuid;cfg jsonb;funding numeric;b numeric;r jsonb;begin
 select buyer_id,rules_snapshot into buyer,cfg from public.orders where id=oid and payment_status='confirmed';if buyer is null then return;end if;
 if cfg='{}'::jsonb then perform private.post_shopping_rewards_legacy(oid);return;end if;
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=oid and a.share_kind='network_rewards';
 select coalesce(sum(trunc(i.ppv_per_unit_snapshot*i.quantity,4)),0) into b from public.order_items i where order_id=oid;
 if b<=0 then return;end if;
 if b*300>funding then raise exception 'Shopping PPV/BV exceeds verified network funding';end if;
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(oid,buyer,funding,b,trunc(b*.35,4)) on conflict do nothing;if not found then return;end if;
 r:=private.distribute_mlm_event(buyer,b,oid,null,cfg);
 update public.shopping_reward_events set direct_generation_mio=(r->>'direct_generation')::numeric,single_line_mio=(r->>'single_line')::numeric where order_id=oid;
end $$;
-- Held bonuses reserve funding, but do not enter an inactive spendable wallet.
do $$declare f text;begin f:=pg_get_functiondef('private.guard_bonus_funding()'::regprocedure);f:=replace(f,'status=''posted''','status in(''posted'',''pending'')');execute f;end $$;
-- Referral-linked purchases use the purchaser's permanent sponsor; no separate affiliate payout.
create or replace function private.guard_company_commission() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.is_company_owned and coalesce(new.commission_rate,0)=0 then new.commission_rate:=.05;end if;
 if new.commission_rate>=.05 then new.sale_distribution:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',new.commission_rate*100-5,'unallocated',0);end if;return new;
end $$;
update public.vendors set sale_distribution=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',commission_rate*100-5,'unallocated',0) where commission_rate>=.05;
create or replace function public.set_vendor_sale_distribution(p_vendor_id uuid,p_split jsonb) returns void language plpgsql security definer set search_path='' as $$begin raise exception 'Separate ecommerce percentage editor is on hold. Use Edit Plans';end $$;
-- PPV is derived by the formula trigger; manual submitted PPV cannot override it.
create or replace function private.guard_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin return new;end $$;
-- Price/commission-derived PPV remains visible before checkout and is saved on each item.
create function private.formula_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$declare rate numeric;begin
 select commission_rate into rate from public.vendors where id=new.vendor_id;
 new.ppv_per_unit:=trunc(new.price_pkr*greatest(coalesce(rate,0)-.05,0)*.90/300,4);return new;
end $$;
create trigger zz_formula_product_ppv before insert or update on public.products for each row execute function private.formula_product_ppv();
update public.products p set ppv_per_unit=trunc(p.price_pkr*greatest(v.commission_rate-.05,0)*.90/300,4) from public.vendors v where v.id=p.vendor_id;
create function private.refresh_vendor_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin if new.commission_rate is distinct from old.commission_rate then update public.products set updated_at=now() where vendor_id=new.id;end if;return new;end $$;
create trigger refresh_vendor_ppv after update of commission_rate on public.vendors for each row execute function private.refresh_vendor_ppv();
-- Read-only alias snapshot no longer demands an active separate selling affiliate.
create or replace function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$declare v public.vendors%rowtype;begin
 select * into v from public.vendors where id=new.vendor_id;
 if v.commission_rate<.05 then raise exception 'Vendor commission must cover company 5 percent';end if;
 new.commission_rate_snapshot:=v.commission_rate;new.company_owned_snapshot:=v.is_company_owned;new.commission_split_snapshot:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',v.commission_rate*100-5,'unallocated',0);new.distribution_basis:='sale_v2';
 new.commission_pool_pkr:=round(new.unit_price_pkr*new.quantity*v.commission_rate,2);new.buyer_discount_pkr:=0;return new;
end $$;
create or replace function private.snapshot_item_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 new.ppv_per_unit_snapshot:=trunc(new.unit_price_pkr*greatest(new.commission_rate_snapshot-.05,0)*.90/300,4);return new;
end $$;
-- Current settings determine entitlement at cycle close; immutable result snapshots keep history.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_close_binary_cycle(text,timestamptz,timestamptz,text)'::regprocedure);
 f:=replace(f,'pool:=trunc(eligible*0.35,4)','pool:=(select coalesce(sum(binary_reserve_mio),0) from public.package_activations where status=''approved'' and source<>''SHOPPING_PPV'' and activated_at>=p_starts_at and activated_at<p_ends_at)');
 f:=replace(f,'a.package_version,a.binary_entitlement','a.package_version,coalesce((private.current_mlm_rules()->''plans''->a.package_code->>''binary_entitlement'')::numeric,a.binary_entitlement) binary_entitlement');execute f;
end $$;
create function public.my_reward_holds() returns jsonb language plpgsql security definer set search_path='' as $$declare uid uuid:=auth.uid();begin
 if uid is null then raise exception 'Sign in required';end if;return jsonb_build_object('direct_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=uid and status='pending'),0),'withdrawal_unlocked',private.package_eligible(uid));end $$;
revoke all on function private.current_mlm_rules(),private.snapshot_mlm_rules(),private.registered_member(uuid),private.release_direct_holds(),private.mlm_candidates(uuid,numeric,jsonb),private.post_network_bonus(uuid,uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric,jsonb),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb),private.credit_activation_bonuses_legacy(uuid),private.credit_activation_bonuses(uuid),private.credit_single_line_legacy(uuid),private.credit_single_line(uuid),private.post_shopping_rewards_legacy(uuid),private.post_shopping_rewards(uuid),private.formula_product_ppv(),private.refresh_vendor_ppv() from public,anon,authenticated;
revoke all on function public.admin_save_plan(text,jsonb,integer),public.my_reward_holds() from public,anon;grant execute on function public.admin_save_plan(text,jsonb,integer),public.my_reward_holds() to authenticated;
revoke all on function public.get_plan_catalog() from public;grant execute on function public.get_plan_catalog() to anon,authenticated;
notify pgrst,'reload schema';
-- Free registered members can inspect their referral tree while earnings remain held.
do $$declare f text;begin f:=pg_get_functiondef('public.my_network(text,text,integer)'::regprocedure);f:=replace(f,'user_id=uid and status=''active''','user_id=uid and status in(''active'',''inactive'') and terms_accepted_at is not null');execute f;end $$;
