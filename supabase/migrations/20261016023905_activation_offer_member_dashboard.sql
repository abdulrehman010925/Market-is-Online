-- First activation starts one 15-day offer. Upgrades do not restart it.
-- Only future direct package-activation events use the promotion; shopping
-- and historical posted transactions retain their existing calculations.
create or replace function private.activation_offer_window(p_member uuid,p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
 with first_plan as (
  select min(coalesce(activated_at,requested_at)) starts_at
  from public.package_activations where member_id=p_member and status='approved'
 ), current_plan as (
  select private.package_eligible(p_member) eligible,
    coalesce((private.current_mlm_rules()->'plans'->private.current_package_code(p_member)->>'direct_rate')::numeric,0) normal_rate
 ) select jsonb_build_object('starts_at',starts_at,'ends_at',starts_at+interval '15 days',
  'eligible',coalesce(eligible and p_at>=starts_at and p_at<starts_at+interval '15 days',false),
  'normal_rate',normal_rate,'offer_rate',.40)
 from first_plan cross join current_plan;
$$;

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
  case when depth=1 then dp_base*case
    when eligible and coalesce((cfg->>'activation_offer_event')::boolean,false)
     and coalesce((private.activation_offer_window(id,coalesce((cfg->>'activation_offer_event_at')::timestamptz,now()))->>'eligible')::boolean,false)
    then .40 else coalesce((plan->>'direct_rate')::numeric,0) end
   else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=open_levels);
$$;

-- Keep all existing distribution/rounding/idempotency paths intact.
alter function private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb) rename to distribute_mlm_event_before_activation_offer;
create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare act public.package_activations%rowtype; sponsor uuid; offer jsonb; allocated numeric; available numeric; outcome jsonb;
begin
 cfg:=cfg-'activation_offer_event'-'activation_offer_event_at';
 if aid is not null and oid is null then
  select * into act from public.package_activations where id=aid;
  select sponsor_id into sponsor from public.member_profiles where user_id=member;
  offer:=private.activation_offer_window(sponsor,coalesce(act.activated_at,now()));
  if act.status='approved' and act.source<>'SHOPPING_PPV' and coalesce((offer->>'eligible')::boolean,false) then
   -- Preserve generation/binary budgets. Any promotional shortfall comes
   -- from this activation's admin fee and is removed from company fee income.
   available:=least(act.bv,act.base_value,act.payable_price-act.company_fee)+act.company_fee;
   allocated:=act.dp*.40
     +act.gp*(coalesce((cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((cfg->>'generation_manager_rate')::numeric,.05)+coalesce((cfg->>'generation_global_rate')::numeric,.20))
     +act.bp*(coalesce((cfg->>'binary_pool_rate')::numeric,.35)+coalesce((cfg->>'single_line_cap')::numeric,.10)+coalesce((cfg->>'binary_manager_rate')::numeric,.05)+coalesce((cfg->>'binary_global_rate')::numeric,.20));
   if allocated>available+.0001 then raise exception 'Activation offer exceeds funded package amount. Review plan budgets.';end if;
   cfg:=cfg||jsonb_build_object('activation_offer_event',true,'activation_offer_event_at',coalesce(act.activated_at,now()),'activation_offer_rate',.40);
  end if;
 end if;
 outcome:=private.distribute_mlm_event_before_activation_offer(member,b,oid,aid,cfg);
 return outcome;
end;
$$;

alter function private.company_treasury_sources_before_ecommerce() rename to company_treasury_sources_before_activation_offer;
create or replace function private.company_treasury_sources_before_ecommerce()
returns table(source_type text,source_id uuid,category text,currency text,amount numeric)
language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.currency,
  case when s.category='package_company_fee' then greatest(0,s.amount-coalesce((
   select greatest(0,
    a.gp*(coalesce((a.rules_snapshot->>'generation_bonus_rate')::numeric,.45)+coalesce((a.rules_snapshot->>'generation_manager_rate')::numeric,.05)+coalesce((a.rules_snapshot->>'generation_global_rate')::numeric,.20))
    +a.bp*(coalesce((a.rules_snapshot->>'binary_pool_rate')::numeric,.35)+coalesce((a.rules_snapshot->>'single_line_cap')::numeric,.10)+coalesce((a.rules_snapshot->>'binary_manager_rate')::numeric,.05)+coalesce((a.rules_snapshot->>'binary_global_rate')::numeric,.20))
    +coalesce((select sum(bt.payable_amount) from public.bonus_transactions bt where bt.source_activation_id=a.id and bt.method='direct' and bt.status in('pending','posted')),0)
    -least(a.bv,a.base_value,a.payable_price-a.company_fee))
   from public.package_activations a where a.id=s.source_id
    and exists(select 1 from public.bonus_transactions bt where bt.source_activation_id=a.id and bt.method='direct' and bt.calculation_trace->'plan_rules'->>'activation_offer_event'='true')
  ),0)) else s.amount end
 from private.company_treasury_sources_before_activation_offer() s;
$$;

create or replace function public.my_member_dashboard()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare member uuid:=auth.uid();p public.member_profiles%rowtype;g jsonb;v_binary jsonb;code text;cfg jsonb;shares numeric:=0;personal_gp numeric:=0;personal_bp numeric:=0;
begin
 if member is null or not private.registered_member(member) then raise exception 'Member account required';end if;
 select * into p from public.member_profiles where user_id=member;
 code:=private.current_package_code(member);cfg:=private.current_mlm_rules();
 g:=public.my_generation_member_details(p.member_code);
 select node into v_binary from jsonb_array_elements(public.my_network('binary',null,1)->'nodes') node where node->>'id'=member::text limit 1;
 select coalesce(sum(completed_shares),0) into shares from private.binary_live_shares(now()) where member_id=member;
 select coalesce(sum(amount) filter(where point_type='GP'),0),coalesce(sum(amount) filter(where point_type='BP'),0)
  into personal_gp,personal_bp from public.point_ledger where member_id=member and created_at>private.financial_reset_at();
 return jsonb_build_object('full_name',p.full_name,'member_code',p.member_code,'profile_photo_url',p.profile_photo_url,
  'enrolled_at',p.created_at,'package_code',code,'package_name',coalesce(cfg->'plans'->code->>'display_name','Free account'),
  'package_active',private.package_eligible(member),'generation',g,'binary',coalesce(v_binary,'{}'::jsonb),
  'personal_gp',personal_gp,'personal_bp',personal_bp,'pending_shares',shares,
  'share_points_each_side',coalesce((cfg->>'binary_share_points_each_side')::numeric,50),
  'activation_offer',private.activation_offer_window(member),'server_now',now());
end;
$$;

revoke all on function private.activation_offer_window(uuid,timestamptz),private.mlm_point_candidates(uuid,numeric,numeric,jsonb),
 private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb),private.distribute_mlm_event_before_activation_offer(uuid,numeric,uuid,uuid,jsonb),
 private.company_treasury_sources_before_ecommerce(),private.company_treasury_sources_before_activation_offer() from public,anon,authenticated;
revoke all on function public.my_member_dashboard() from public,anon;
grant execute on function public.my_member_dashboard() to authenticated;
notify pgrst,'reload schema';
