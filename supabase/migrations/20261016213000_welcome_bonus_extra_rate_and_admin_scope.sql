-- Welcome Bonus is an extra percentage of the sponsor's direct DP, not a
-- top-up to a universal 40%. Existing offers use 10% on future events; already
-- posted bonuses remain immutable. Future first activations snapshot the admin rate.
insert into public.system_config(config_key,version,config_value,effective_from)
values('WELCOME_BONUS_RATE',1,'0.10'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

alter table private.member_welcome_bonus_eligibility
 add column if not exists bonus_rate numeric(8,6) not null default .10
 check (bonus_rate between 0 and .10);
update private.member_welcome_bonus_eligibility set bonus_rate=.10
 where bonus_rate is distinct from .10;

create or replace function private.capture_welcome_bonus_eligibility()
returns trigger language plpgsql security definer set search_path='' as $$
declare is_enabled boolean; starts timestamptz; configured_rate numeric;
begin
 if new.status<>'approved' or (tg_op='UPDATE' and old.status='approved') then return new; end if;
 if exists(select 1 from private.member_welcome_bonus_eligibility where member_id=new.member_id) then return new; end if;
 select coalesce(config_value,'true'::jsonb)='true'::jsonb into is_enabled
 from public.system_config where config_key='WELCOME_BONUS' and effective_to is null
 order by version desc limit 1;
 select (config_value #>> '{}')::numeric into configured_rate
 from public.system_config where config_key='WELCOME_BONUS_RATE' and effective_to is null
 order by version desc limit 1;
 is_enabled:=coalesce(is_enabled,true);
 configured_rate:=coalesce(configured_rate,.10);
 starts:=coalesce(new.activated_at,new.requested_at,clock_timestamp());
 insert into private.member_welcome_bonus_eligibility(member_id,enabled,started_at,ends_at,bonus_rate)
 values(new.member_id,is_enabled,case when is_enabled then starts end,
  case when is_enabled then starts+interval '15 days' end,configured_rate)
 on conflict(member_id) do nothing;
 return new;
end $$;

create or replace function private.activation_offer_window(p_member uuid,p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
 with decision as (
  select enabled,started_at,ends_at,bonus_rate
  from private.member_welcome_bonus_eligibility
  where member_id=p_member
 ), current_plan as (
  select private.package_eligible(p_member) eligible,
   coalesce((private.current_mlm_rules()->'plans'->private.current_package_code(p_member)->>'direct_rate')::numeric,0) normal_rate
 ), current_setting as (
  select coalesce((select config_value='true'::jsonb from public.system_config
   where config_key='WELCOME_BONUS' and effective_to is null order by version desc limit 1),true) feature_enabled
 )
 select jsonb_build_object(
  'starts_at',d.started_at,
  'ends_at',d.ends_at,
  'eligible',coalesce(c.eligible and d.enabled and p_at>=d.started_at and p_at<d.ends_at,false),
  'enabled',coalesce(d.enabled,false),
  'enrolled',d.member_id is not null,
  'feature_enabled',s.feature_enabled,
  'normal_rate',c.normal_rate,
  'welcome_rate',coalesce(d.bonus_rate,0),
  'offer_rate',c.normal_rate+coalesce(d.bonus_rate,0)
 )
 from current_plan c cross join current_setting s
 left join (select p_member member_id,decision.* from decision) d on true;
$$;

create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare act public.package_activations%rowtype;sponsor uuid;offer jsonb;allocated numeric;available numeric;outcome jsonb;
 normal_rate numeric:=0;target_rate numeric:=0;welcome_rate numeric:=0;welcome_amount numeric:=0;tx uuid;state text;event_at timestamptz;
begin
 cfg:=cfg-'activation_offer_event'-'activation_offer_event_at'-'activation_offer_rate'-'activation_offer_normal_rate'-'activation_offer_welcome_rate';
 if aid is not null and oid is null then
  select * into act from public.package_activations where id=aid;
  select sponsor_id into sponsor from public.member_profiles where user_id=member;
  event_at:=coalesce(act.activated_at,now());
  offer:=private.activation_offer_window(sponsor,event_at);
  if act.status='approved' and act.source<>'SHOPPING_PPV' and coalesce((offer->>'eligible')::boolean,false) then
   normal_rate:=coalesce((offer->>'normal_rate')::numeric,0);
   welcome_rate:=coalesce((offer->>'welcome_rate')::numeric,.10);
   target_rate:=normal_rate+welcome_rate;
   available:=least(act.bv,act.base_value,act.payable_price-act.company_fee)+act.company_fee;
   allocated:=act.dp*target_rate
     +act.gp*(coalesce((cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((cfg->>'generation_manager_rate')::numeric,.05)+coalesce((cfg->>'generation_global_rate')::numeric,.20))
     +act.bp*(coalesce((cfg->>'binary_pool_rate')::numeric,.35)+coalesce((cfg->>'single_line_cap')::numeric,.10)+coalesce((cfg->>'binary_manager_rate')::numeric,.05)+coalesce((cfg->>'binary_global_rate')::numeric,.20));
   if allocated>available+.0001 then raise exception 'Activation offer exceeds funded package amount. Review plan budgets.';end if;
   cfg:=cfg||jsonb_build_object('activation_offer_event',true,'activation_offer_event_at',event_at,'activation_offer_rate',target_rate,
    'activation_offer_normal_rate',normal_rate,'activation_offer_welcome_rate',welcome_rate);
  end if;
 end if;
 outcome:=private.distribute_mlm_event_before_activation_offer(member,b,oid,aid,cfg);
 if sponsor is not null and welcome_rate>0 then
  welcome_amount:=trunc(act.dp*welcome_rate,4);
  insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
  values(sponsor,'direct',aid,1,act.dp,welcome_rate,welcome_amount,welcome_amount,'MIO','activation-welcome-v1',
   jsonb_build_object('plan_rules',cfg,'bonus_component','welcome_bonus','display_label','Welcome Bonus (Sponsor)',
    'normal_sponsor_rate',normal_rate,'welcome_rate',welcome_rate,'offer_rate',target_rate,'offer_started_at',offer->>'starts_at','offer_ends_at',offer->>'ends_at',
    'nominal_mio',welcome_amount,'funded_mio',welcome_amount,'depth',1),
   'welcome:'||aid||':'||sponsor)
  on conflict(idempotency_key) do nothing returning id,status into tx,state;
  if tx is not null and state='posted' then
   update public.mio_wallet_accounts set balance=balance+welcome_amount,updated_at=now() where member_id=sponsor;
   if not found then raise exception 'Recipient wallet missing';end if;
   insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
   values(sponsor,welcome_amount,'bonus_credit',aid,tx,'Welcome Bonus (Sponsor)','bonus:'||tx);
  end if;
  outcome:=jsonb_set(outcome,'{direct}',to_jsonb(coalesce((outcome->>'direct')::numeric,0)+welcome_amount));
  outcome:=jsonb_set(outcome,'{direct_generation}',to_jsonb(coalesce((outcome->>'direct_generation')::numeric,0)+welcome_amount));
 end if;
 return outcome;
end;
$$;

create or replace function public.admin_set_welcome_bonus_rate(p_rate numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_rate is null or p_rate<0 or p_rate>.10 or p_rate<>round(p_rate,4)
 then raise exception 'Welcome Bonus must be between 0 and 10 percent, in 0.01 percent steps'; end if;
 perform pg_advisory_xact_lock(hashtextextended('welcome-bonus-rate-setting',0));
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='WELCOME_BONUS_RATE';
 update public.system_config set effective_to=clock_timestamp()
 where config_key='WELCOME_BONUS_RATE' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('WELCOME_BONUS_RATE',v,to_jsonb(p_rate),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'WELCOME_BONUS_RATE_SET','system_config',jsonb_build_object('rate',p_rate,'version',v));
 return jsonb_build_object('rate',p_rate,'version',v);
end $$;

revoke all on function private.capture_welcome_bonus_eligibility(),private.activation_offer_window(uuid,timestamptz),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.admin_set_welcome_bonus_rate(numeric) from public,anon;
grant execute on function public.admin_set_welcome_bonus_rate(numeric) to authenticated;
notify pgrst,'reload schema';
