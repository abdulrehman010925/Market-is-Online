-- Package PPV is gross paid value; BV/DP and GP/BP remain funded base points.
alter table public.shopping_reward_events add column if not exists brp numeric(18,4) not null default 0;
create or replace function private.normalize_package_version_values()
returns trigger language plpgsql set search_path=''
as $function$
begin
 if new.base_value<=0 then raise exception 'Package base value must be positive';end if;
 if new.company_fee<0 then raise exception 'Package company fee cannot be negative';end if;
 new.company_fee:=round(new.company_fee,4);new.ppv:=round(new.base_value+new.company_fee,4);return new;
end
$function$;
update public.package_versions set ppv=payable_price,
 binary_entitlement=case package_code when 'BASIC_1' then .50 when 'BASIC_2' then .60 when 'ADVANCED_1' then .70 when 'ADVANCED_2' then .80 when 'PREMIUM' then 1 else binary_entitlement end
where is_active;
do $plans$
declare cfg jsonb;v integer;code text;plan jsonb;actor uuid;
begin
 select config_value into cfg from public.system_config where config_key='MLM_PLANS' and effective_to is null order by version desc limit 1 for update;
 if cfg is not null and coalesce((cfg->'plans'->'BASIC_1'->>'ppv')::numeric,0)<>11 then
  v:=coalesce((cfg->>'version')::integer,0)+1;
  for code in select jsonb_object_keys(cfg->'plans') loop
   plan:=cfg->'plans'->code;
   plan:=jsonb_set(plan,'{ppv}',to_jsonb((plan->>'payable_price')::numeric),true);
   plan:=jsonb_set(plan,'{company_fee_rate}',to_jsonb(round((plan->>'company_fee')::numeric/nullif((plan->>'base_value')::numeric,0),8)),true);
   plan:=jsonb_set(plan,'{binary_entitlement}',to_jsonb(case code when 'BASIC_1' then .50 when 'BASIC_2' then .60 when 'ADVANCED_1' then .70 when 'ADVANCED_2' then .80 else 1 end::numeric),true);
   plan:=jsonb_set(plan,'{single_line_levels}',to_jsonb(case code when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 else 30 end),true);
   cfg:=jsonb_set(cfg,array['plans',code],plan,true);
  end loop;
  cfg:=jsonb_set(jsonb_set(cfg,'{shopping_admin_fee_rate}','0.10'::jsonb,true),'{version}',to_jsonb(v),true);
  select user_id into actor from public.user_roles where role='admin' order by created_at limit 1;
  update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MLM_PLANS',v,cfg,clock_timestamp(),actor);
 end if;
end
$plans$;
update public.point_ledger pl set amount=a.payable_price from public.package_activations a
where pl.source_activation_id=a.id and pl.point_type='PPV' and a.status='approved' and a.source<>'SHOPPING_PPV' and pl.amount is distinct from a.payable_price;
update public.package_activations set ppv=payable_price where status='approved' and ppv is distinct from payable_price;

-- One cumulative PPV cap across package activation and delivered shopping.
do $config$
declare cfg public.system_config%rowtype;next_version integer;
begin
 select * into cfg from public.system_config where config_key='PPV_CAPS' and effective_to is null order by version desc limit 1 for update;
 if cfg.config_key is not null and coalesce(cfg.config_value->>'mode_lock','')<>'MIO_AFTER_TOTAL_PPV_CAP' then
  next_version:=cfg.version+1;
  update public.system_config set effective_to=clock_timestamp() where config_key='PPV_CAPS' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
  values('PPV_CAPS',next_version,jsonb_set(jsonb_set(cfg.config_value,'{total_ppv_cap}','110'::jsonb,true),'{mode_lock}',to_jsonb('MIO_AFTER_TOTAL_PPV_CAP'::text),true),clock_timestamp(),cfg.created_by);
 end if;
end
$config$;

create or replace function private.shopping_ppv_cap_status(p_member uuid)
returns table(cap numeric,used numeric,remaining numeric,locked boolean)
language sql stable security definer set search_path=''
as $function$
with settings as(select coalesce((select coalesce((config_value->>'total_ppv_cap')::numeric,(config_value->>'shopping_ppv_cap')::numeric) from public.system_config where config_key='PPV_CAPS' and effective_to is null order by version desc limit 1),110)::numeric cap),
usage as(select coalesce(sum(amount),0)::numeric used from public.point_ledger where member_id=p_member and point_type='PPV' and created_at>private.financial_reset_at())
select settings.cap,usage.used,greatest(settings.cap-usage.used,0),usage.used>=settings.cap from settings cross join usage
$function$;

create or replace function private.cap_total_ppv_credit()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare s record;
begin
 if new.point_type='PPV' and new.amount>0 then
  perform pg_advisory_xact_lock(hashtextextended('total-ppv:'||new.member_id::text,0));
  select * into s from private.shopping_ppv_cap_status(new.member_id);
  if s.remaining<=0 then
   update public.member_profiles set shopping_reward_mode='MIO',updated_at=now() where user_id=new.member_id and shopping_reward_mode<>'MIO';
   return null;
  end if;
  new.amount:=least(new.amount,s.remaining);
  if new.amount>=s.remaining then update public.member_profiles set shopping_reward_mode='MIO',updated_at=now() where user_id=new.member_id and shopping_reward_mode<>'MIO';end if;
 end if;
 return new;
end
$function$;
drop trigger if exists point_ledger_cap_total_ppv on public.point_ledger;
create trigger point_ledger_cap_total_ppv before insert on public.point_ledger for each row execute function private.cap_total_ppv_credit();

insert into public.audit_logs(action,entity_type,before_data,after_data)
select 'TOTAL_PPV_CAP_RECONCILIATION','point_ledger',jsonb_build_object('members_over_cap',count(*),'excess_ppv',coalesce(sum(used-cap),0)),jsonb_build_object('cap',110,'method','audited cap adjustment','credits_deleted',false)
from(select member_id,sum(amount) used,110::numeric cap from public.point_ledger where point_type='PPV' and created_at>private.financial_reset_at() group by member_id having sum(amount)>110)x;
with over_cap as(select member_id,sum(amount)-110 excess from public.point_ledger where point_type='PPV' and created_at>private.financial_reset_at() group by member_id having sum(amount)>110),
source_row as(select o.member_id,o.excess,p.source_activation_id,p.source_order_id from over_cap o cross join lateral(select source_activation_id,source_order_id from public.point_ledger p where p.member_id=o.member_id and p.point_type='PPV' order by p.created_at desc,p.id desc limit 1)p)
insert into public.point_ledger(member_id,point_type,amount,source_activation_id,source_order_id,entry_kind,idempotency_key)
select member_id,'PPV',-excess,source_activation_id,source_order_id,'adjustment','unified-total-ppv-cap:110:'||member_id from source_row on conflict(idempotency_key) do nothing;

create or replace function public.my_ppv_cap_status()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare uid uuid:=auth.uid();s record;mode text;
begin
 if uid is null then raise exception 'Sign in first';end if;
 select * into s from private.shopping_ppv_cap_status(uid);select shopping_reward_mode into mode from public.member_profiles where user_id=uid;
 return jsonb_build_object('mode',case when s.locked then 'MIO' else coalesce(mode,'PPV') end,'eligible',private.package_eligible(uid),'shopping_ppv_used',s.used,'shopping_ppv_cap',s.cap,'shopping_ppv_remaining',s.remaining,'shopping_ppv_locked',s.locked);
end
$function$;
create or replace function public.set_shopping_reward_mode(p_mode text)
returns void language plpgsql security definer set search_path=''
as $function$
declare uid uuid:=auth.uid();s record;
begin
 if uid is null or not private.package_eligible(uid) then raise exception 'Activate any package to choose MIO rewards';end if;
 if p_mode is null or p_mode not in('PPV','MIO') then raise exception 'Choose PPV or MIO';end if;
 select * into s from private.shopping_ppv_cap_status(uid);
 if p_mode='PPV' and s.locked then update public.member_profiles set shopping_reward_mode='MIO',updated_at=now() where user_id=uid;raise exception 'Your total PPV cap of % is complete. MIO mode is now required.',s.cap;end if;
 update public.member_profiles set shopping_reward_mode=p_mode,updated_at=now() where user_id=uid;
end
$function$;
create or replace function private.snapshot_order_reward_mode()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare code text:=upper(trim(coalesce(current_setting('mio.affiliate_code',true),'')));seller uuid;cap_locked boolean:=false;
begin
 if code<>'' then select user_id into seller from public.member_profiles where (upper(member_code)=code or upper(replace(member_code,'MIO-',''))=code or upper(referral_code)=regexp_replace(code,'-[LR]$','')) and status in('active','inactive') and terms_accepted_at is not null;if seller is null then raise exception 'Selling link is no longer valid';end if;end if;
 if seller=new.buyer_id then seller:=null;end if;new.selling_affiliate_id:=seller;new.reward_owner_id:=coalesce(seller,new.buyer_id);
 select case when private.package_eligible(user_id) then shopping_reward_mode else 'PPV' end,sponsor_id into new.reward_mode,new.reward_sponsor_id from public.member_profiles where user_id=new.reward_owner_id;
 if new.reward_owner_id is not null then select s.locked into cap_locked from private.shopping_ppv_cap_status(new.reward_owner_id)s;end if;
 if cap_locked then new.reward_mode:='MIO';update public.member_profiles set shopping_reward_mode='MIO',updated_at=now() where user_id=new.reward_owner_id;end if;
 select sponsor_id into new.reward_second_sponsor_id from public.member_profiles where user_id=new.reward_sponsor_id;new.reward_mode:=coalesce(new.reward_mode,'PPV');return new;
end
$function$;

update public.member_profiles mp set shopping_reward_mode='MIO',updated_at=now() where shopping_reward_mode<>'MIO' and exists(select 1 from private.shopping_ppv_cap_status(mp.user_id)s where s.locked);

create or replace function private.release_order_rewards()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare o public.orders%rowtype;ppv numeric;total numeric;funding numeric;r record;outcome jsonb;net_base numeric;dp_base numeric;gp_base numeric;bp_base numeric;brp_base numeric;fee_rate numeric:=.10;cap numeric:=110;used numeric:=0;
begin
 select * into o from public.orders where id=new.id for update;
 if o.status in('cancelled','returned') and o.rewards_credited_at is null then update public.ecommerce_rewards set status='cancelled' where order_id=o.id and status='pending_delivery';return new;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if o.reward_owner_id is null then update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;end if;
 if o.reward_mode='PPV' then select s.cap,s.used into cap,used from private.shopping_ppv_cap_status(o.reward_owner_id)s;ppv:=least(ppv,greatest(0,cap-used));end if;
 if o.reward_version=1 then o.reward_owner_id:=o.buyer_id;perform private.post_shopping_rewards(o.id);
 else
  select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards';
  if ppv*300>funding then raise exception 'Order rewards exceed verified funding';end if;
  if o.reward_mode='MIO' then for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop perform private.credit_ecommerce_reward(r.id);end loop;update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;
  elsif ppv>0 then
   fee_rate:=coalesce((o.rules_snapshot->>'shopping_admin_fee_rate')::numeric,.10);if fee_rate<0 or fee_rate>1 then raise exception 'Invalid shopping admin fee rate';end if;
   net_base:=trunc(ppv/(1+fee_rate),4);dp_base:=trunc(net_base*coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric,1),4);gp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric,.5),4);bp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric,.5),4);brp_base:=bp_base;
   insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,dp,gp,bp,brp,binary_reserve_mio) values(o.id,o.reward_owner_id,funding,net_base,dp_base,gp_base,bp_base,brp_base,trunc(bp_base*coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric,.35),4)) on conflict do nothing;
   if found then outcome:=private.distribute_mlm_event(o.reward_owner_id,dp_base,o.id,null,o.rules_snapshot);update public.shopping_reward_events set direct_generation_mio=(outcome->>'direct_generation')::numeric,single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;end if;
  end if;
 end if;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id||':ppv') on conflict(idempotency_key) do nothing;end if;
 if o.reward_mode='PPV' and used+ppv>=cap then update public.member_profiles set shopping_reward_mode='MIO',updated_at=now() where user_id=o.reward_owner_id;end if;
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.reward_owner_id and point_type='PPV';perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);perform private.sync_company_treasury();return new;
end
$function$;
revoke all on function private.shopping_ppv_cap_status(uuid),private.cap_total_ppv_credit(),private.snapshot_order_reward_mode(),private.release_order_rewards() from public,anon,authenticated;
revoke all on function public.my_ppv_cap_status(),public.set_shopping_reward_mode(text) from public,anon;
grant execute on function public.my_ppv_cap_status(),public.set_shopping_reward_mode(text) to authenticated;
notify pgrst,'reload schema';
