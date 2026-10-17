-- Keep the 15-day direct offer at 40%, but post it as two auditable rows:
-- the sponsor's normal package rate and the promotional welcome difference.
create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor
  where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,
   private.package_eligible(u.id) eligible,private.generation_levels_by_dp(u.id,cfg) open_levels
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*coalesce((plan->>'direct_rate')::numeric,0)
   else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=open_levels);
$$;

create or replace function private.guard_bonus_funding()
returns trigger language plpgsql security definer set search_path='' as $$
declare spent numeric;ceiling numeric;cfg jsonb;trace_cfg jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then
   select s.dp,s.gp,s.bp,o.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else
   select a.dp,a.gp,a.bp,a.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;
  end if;
  trace_cfg:=coalesce(new.calculation_trace->'plan_rules','{}'::jsonb);
  if new.method='direct' then
   ceiling:=trunc(dp_base*coalesce((trace_cfg->>'activation_offer_rate')::numeric,new.rate),4);
  elsif new.method='generation' then ceiling:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);
  else ceiling:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);end if;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions
   where status in('posted','pending')
    and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id))
    and method=new.method;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling+.0001 then raise exception 'Bonus would exceed its funded source budget';end if;
 return new;
end$$;

create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare act public.package_activations%rowtype;sponsor uuid;offer jsonb;allocated numeric;available numeric;outcome jsonb;
 normal_rate numeric:=0;welcome_rate numeric:=0;welcome_amount numeric:=0;tx uuid;state text;event_at timestamptz;
begin
 cfg:=cfg-'activation_offer_event'-'activation_offer_event_at'-'activation_offer_rate'-'activation_offer_normal_rate'-'activation_offer_welcome_rate';
 if aid is not null and oid is null then
  select * into act from public.package_activations where id=aid;
  select sponsor_id into sponsor from public.member_profiles where user_id=member;
  event_at:=coalesce(act.activated_at,now());
  offer:=private.activation_offer_window(sponsor,event_at);
  if act.status='approved' and act.source<>'SHOPPING_PPV' and coalesce((offer->>'eligible')::boolean,false) then
   normal_rate:=coalesce((offer->>'normal_rate')::numeric,0);
   welcome_rate:=greatest(0,.40-normal_rate);
   available:=least(act.bv,act.base_value,act.payable_price-act.company_fee)+act.company_fee;
   allocated:=act.dp*.40
     +act.gp*(coalesce((cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((cfg->>'generation_manager_rate')::numeric,.05)+coalesce((cfg->>'generation_global_rate')::numeric,.20))
     +act.bp*(coalesce((cfg->>'binary_pool_rate')::numeric,.35)+coalesce((cfg->>'single_line_cap')::numeric,.10)+coalesce((cfg->>'binary_manager_rate')::numeric,.05)+coalesce((cfg->>'binary_global_rate')::numeric,.20));
   if allocated>available+.0001 then raise exception 'Activation offer exceeds funded package amount. Review plan budgets.';end if;
   cfg:=cfg||jsonb_build_object('activation_offer_event',true,'activation_offer_event_at',event_at,'activation_offer_rate',.40,
    'activation_offer_normal_rate',normal_rate,'activation_offer_welcome_rate',welcome_rate);
  end if;
 end if;
 outcome:=private.distribute_mlm_event_before_activation_offer(member,b,oid,aid,cfg);
 if sponsor is not null and welcome_rate>0 then
  welcome_amount:=trunc(act.dp*welcome_rate,4);
  insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
  values(sponsor,'direct',aid,1,act.dp,welcome_rate,welcome_amount,welcome_amount,'MIO','activation-welcome-v1',
   jsonb_build_object('plan_rules',cfg,'bonus_component','welcome_bonus','display_label','Welcome Bonus (Sponsor)',
    'normal_sponsor_rate',normal_rate,'welcome_rate',welcome_rate,'offer_rate',.40,'offer_started_at',offer->>'starts_at','offer_ends_at',offer->>'ends_at',
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

revoke all on function private.mlm_point_candidates(uuid,numeric,numeric,jsonb),private.guard_bonus_funding(),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';
