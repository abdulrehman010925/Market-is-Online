-- Generation earnings require the selected plan, its active-direct target and its DP target.
do $$
declare cfg jsonb; next_version integer; code text; levels integer;
begin
  select config_value into cfg
  from public.system_config
  where config_key='MLM_PLANS' and effective_to is null
  order by version desc limit 1 for update;

  next_version:=coalesce((cfg->>'version')::integer,0)+1;
  for code in select jsonb_object_keys(cfg->'plans') loop
    levels:=coalesce((cfg->'plans'->code->>'max_generations')::integer,0);
    cfg:=jsonb_set(cfg,array['plans',code,'generation_required_directs'],to_jsonb(ceil(levels/2.0)::integer),true);
    cfg:=jsonb_set(cfg,array['plans',code,'generation_required_dp'],to_jsonb((levels*10)::numeric),true);
  end loop;
  cfg:=jsonb_set(cfg,'{version}',to_jsonb(next_version),true);

  update public.system_config set effective_to=clock_timestamp()
  where config_key='MLM_PLANS' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
  values('MLM_PLANS',next_version,cfg,clock_timestamp(),
    (select user_id from public.user_roles where role='admin' order by user_id limit 1));
end
$$;

create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer
language sql stable security definer set search_path=''
as $$
 with plan as (
  select p,
   coalesce((p->>'max_generations')::integer,0) package_levels,
   coalesce((p->>'generation_required_directs')::integer,ceil(coalesce((p->>'max_generations')::numeric,0)/2)::integer) required_directs,
   coalesce((p->>'generation_required_dp')::numeric,coalesce((p->>'max_generations')::numeric,0)*10) required_dp
  from (select p_cfg->'plans'->coalesce(private.current_package_code(p_member),'BASIC_1') p) q
 ), d as (
  select * from private.direct_dp_summary(p_member)
 )
 select case when d.active_directs>=plan.required_directs and d.total_dp>=plan.required_dp
             then plan.package_levels else 0 end
 from plan cross join d;
$$;

create or replace function public.admin_save_plan(p_code text,p_plan jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;required_directs integer;required_dp numeric;rate numeric;tot numeric;key text;gplan numeric;bplan numeric;genbonus numeric;genmanager numeric;genglobal numeric;placement numeric;pool numeric;bmanager numeric;bglobal numeric;
begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;perform private.require_recent_totp();perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 foreach key in array array['generation_plan_rate','binary_plan_rate','generation_bonus_rate','generation_manager_rate','generation_global_rate','single_line_cap','binary_pool_rate','binary_manager_rate','binary_global_rate'] loop if jsonb_typeof(p_plan->key)<>'number' then raise exception 'Missing numeric budget: %',key;end if;end loop;
 gplan:=(p_plan->>'generation_plan_rate')::numeric;bplan:=(p_plan->>'binary_plan_rate')::numeric;genbonus:=(p_plan->>'generation_bonus_rate')::numeric;genmanager:=(p_plan->>'generation_manager_rate')::numeric;genglobal:=(p_plan->>'generation_global_rate')::numeric;placement:=(p_plan->>'single_line_cap')::numeric;pool:=(p_plan->>'binary_pool_rate')::numeric;bmanager:=(p_plan->>'binary_manager_rate')::numeric;bglobal:=(p_plan->>'binary_global_rate')::numeric;
 if least(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)<0 or greatest(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)>1 then raise exception 'All percentages must be between 0 and 100';end if;
 if abs(gplan+bplan-1)>.000000001 then raise exception 'Generation Plan and Binary Plan must total exactly 100 percent';end if;if genbonus+genmanager+genglobal>1.000000001 then raise exception 'Generation breakdown exceeds 100 percent of GP';end if;if placement+pool+bmanager+bglobal>1.000000001 then raise exception 'Binary breakdown exceeds 100 percent of BP';end if;
 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','company_fee','ppv','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','generation_required_directs','generation_required_dp','single_line_levels'] loop if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 then raise exception 'Invalid plan value: %',key;end if;end loop;
 if (p_plan->>'base_value')::numeric<=0 or (p_plan->>'ppv')::numeric<=0 or (p_plan->>'bv')::numeric>(p_plan->>'base_value')::numeric or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;if (p_plan->>'bv')::numeric>(p_plan->>'ppv')::numeric then raise exception 'BV cannot exceed PPV';end if;
 if abs((p_plan->>'gp')::numeric-(p_plan->>'dp')::numeric*gplan)>.0001 or abs((p_plan->>'bp')::numeric-(p_plan->>'dp')::numeric*bplan)>.0001 then raise exception 'GP and BP must follow the configured DP plan split';end if;
 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;required_directs:=(p_plan->>'generation_required_directs')::integer;required_dp:=(p_plan->>'generation_required_dp')::numeric;
 if levels not between 1 and 10 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–10; binary placement limit 1–30';end if;
 if required_directs not between 0 and 100 or (p_plan->>'generation_required_directs')::numeric<>required_directs or required_dp<0 then raise exception 'Generation qualification requires a whole direct-member count and non-negative DP';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 tot:=0;for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;tot:=tot+rate;end loop;if tot>genbonus+.000000001 then raise exception 'Generation levels exceed the Generation bonus budget';end if;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid binary placement rate';end if;tot:=tot+rate;end loop;if tot>placement+.000000001 then raise exception 'Binary placement levels exceed their budget';end if;
 cfg:=cfg||jsonb_build_object('generation_plan_rate',gplan,'binary_plan_rate',bplan,'generation_bonus_rate',genbonus,'generation_manager_rate',genmanager,'generation_global_rate',genglobal,'single_line_cap',placement,'binary_pool_rate',pool,'binary_manager_rate',bmanager,'binary_global_rate',bglobal);
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement) values(p_code,old.version+1,old.display_name,(p_plan->>'base_value')::numeric,(p_plan->>'company_fee')::numeric,(p_plan->>'ppv')::numeric,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels,'generation_required_directs',required_directs,'generation_required_dp',required_dp) into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'generation_plan',jsonb_build_object('split',gplan,'generation',genbonus,'manager',genmanager,'global',genglobal),'binary_plan',jsonb_build_object('split',bplan,'pool',pool,'placement',placement,'manager',bmanager,'global',bglobal)));
 return cfg;
end$$;

revoke all on function private.generation_levels_by_dp(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.admin_save_plan(text,jsonb,integer) to authenticated;
notify pgrst,'reload schema';
