-- Admin-controlled bonus destinations. Existing balances are not changed.
create or replace function private.default_bonus_wallet_routes()
returns jsonb language sql immutable set search_path to '' as $function$
select jsonb_build_object(
 'direct_sponsor','cash','welcome_bonus','cash','generation','proceed',
 'binary_placement','proceed','binary_pool_share','proceed',
 'ecommerce_cashback','cash','ecommerce_affiliate_level1','cash',
 'ecommerce_level2','proceed','vendor_introducer','proceed')
$function$;

insert into public.system_config(config_key,version,config_value,effective_from,effective_to,created_by)
select 'BONUS_WALLET_ROUTING',1,private.default_bonus_wallet_routes(),now(),null,null
where not exists(select 1 from public.system_config where config_key='BONUS_WALLET_ROUTING');

create or replace function private.current_bonus_wallet_routing()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_version integer:=0;v_routes jsonb:='{}'::jsonb;
begin
 select version,config_value into v_version,v_routes
 from public.system_config where config_key='BONUS_WALLET_ROUTING'
 and effective_from<=now() and (effective_to is null or effective_to>now())
 order by version desc limit 1;
 return jsonb_build_object('version',coalesce(v_version,0),
  'routes',private.default_bonus_wallet_routes()||coalesce(v_routes,'{}'::jsonb));
end $function$;

create or replace function private.network_bonus_wallet_route_key(p_method public.bonus_method,p_trace jsonb)
returns text language sql immutable set search_path to '' as $function$
select case
 when p_method='direct'::public.bonus_method and coalesce(p_trace->>'bonus_component','')='welcome_bonus' then 'welcome_bonus'
 when p_method='direct'::public.bonus_method then 'direct_sponsor'
 when p_method='generation'::public.bonus_method then 'generation'
 when p_method='single_line'::public.bonus_method then 'binary_placement'
 when p_method='binary_pool_share'::public.bonus_method then 'binary_pool_share'
 else p_method::text end
$function$;

create or replace function private.ecommerce_bonus_wallet_route_key(p_reward_kind text)
returns text language sql immutable set search_path to '' as $function$
select case
 when p_reward_kind='cashback' then 'ecommerce_cashback'
 when p_reward_kind in('affiliate','sponsor') then 'ecommerce_affiliate_level1'
 when p_reward_kind='second_sponsor' then 'ecommerce_level2'
 when p_reward_kind='vendor_introducer' then 'vendor_introducer'
 else 'ecommerce_level2' end
$function$;

create or replace function public.admin_bonus_wallet_routing()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_snapshot jsonb;v_updated_at timestamptz;v_updated_by uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 v_snapshot:=private.current_bonus_wallet_routing();
 select effective_from,created_by into v_updated_at,v_updated_by
 from public.system_config where config_key='BONUS_WALLET_ROUTING' and effective_to is null
 order by version desc limit 1;
 return v_snapshot||jsonb_build_object('updated_at',v_updated_at,'updated_by',v_updated_by);
end $function$;

create or replace function public.admin_set_bonus_wallet_routing(p_routes jsonb,p_expected_version integer)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
 v_keys text[]:=array['direct_sponsor','welcome_bonus','generation','binary_placement',
 'binary_pool_share','ecommerce_cashback','ecommerce_affiliate_level1',
 'ecommerce_level2','vendor_introducer'];
 v_key text;v_current_version integer:=0;v_current_routes jsonb;v_new_version integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_routes is null or jsonb_typeof(p_routes)<>'object' then raise exception 'A complete wallet routing object is required';end if;
 foreach v_key in array v_keys loop
  if coalesce(p_routes->>v_key,'') not in('cash','proceed') then
   raise exception 'Choose Cash Wallet or Proceed Wallet for %',v_key;
  end if;
 end loop;
 if exists(select 1 from jsonb_object_keys(p_routes) supplied(key) where not(supplied.key=any(v_keys))) then
  raise exception 'Unknown bonus wallet routing key';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('BONUS_WALLET_ROUTING',0));
 select version,config_value into v_current_version,v_current_routes
 from public.system_config where config_key='BONUS_WALLET_ROUTING' and effective_to is null
 order by version desc limit 1;
 v_current_version:=coalesce(v_current_version,0);
 if p_expected_version is null or p_expected_version<>v_current_version then
  raise exception 'Wallet routing was updated by another session. Refresh and try again.';
 end if;
 v_new_version:=v_current_version+1;
 update public.system_config set effective_to=now()
 where config_key='BONUS_WALLET_ROUTING' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,effective_to,created_by)
 values('BONUS_WALLET_ROUTING',v_new_version,p_routes,now(),null,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,before_data,after_data)
 values(auth.uid(),'BONUS_WALLET_ROUTING_UPDATED','system_config',
 jsonb_build_object('version',v_current_version,'routes',v_current_routes),
 jsonb_build_object('version',v_new_version,'routes',p_routes));
 return private.current_bonus_wallet_routing();
end $function$;

create or replace function private.route_bonus_to_income_wallet()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare v_snapshot jsonb;v_route_key text;v_target text;v_inserted_count integer;
begin
 if new.status<>'posted' or new.payable_amount<=0 then return new;end if;
 if tg_op='UPDATE' and old.status='posted' then return new;end if;
 v_snapshot:=private.current_bonus_wallet_routing();
 v_route_key:=private.network_bonus_wallet_route_key(new.method,new.calculation_trace);
 v_target:=coalesce(v_snapshot->'routes'->>v_route_key,'proceed');
 insert into public.member_income_wallets(member_id) values(new.beneficiary_id)
 on conflict(member_id) do nothing;
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,source_bonus_id,note,metadata,idempotency_key)
 values(new.beneficiary_id,v_target,new.payable_amount,'network_earning',new.id,
 case when v_target='cash' then 'Network earning routed to Cash Wallet' else 'Network earning routed to Proceed Wallet' end,
 jsonb_build_object('method',new.method,'generation',new.generation,'formula_version',new.formula_version,
 'routing_key',v_route_key,'routing_version',v_snapshot->>'version','target_wallet',v_target),
 'bonus-route:'||new.id) on conflict(idempotency_key) do nothing;
 get diagnostics v_inserted_count=row_count;
 if v_inserted_count=1 and v_target='proceed' then
  update public.mio_wallet_accounts set balance=balance-new.payable_amount,updated_at=now()
  where member_id=new.beneficiary_id and balance>=new.payable_amount;
  if not found then raise exception 'Cash wallet routing reconciliation failed';end if;
  update public.member_income_wallets set proceed_mio=proceed_mio+new.payable_amount,updated_at=now()
  where member_id=new.beneficiary_id;
 end if;
 return new;
end $function$;

create or replace function private.route_ecommerce_to_income_wallet()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare v_snapshot jsonb;v_route_key text;v_target text;v_inserted_count integer;
begin
 if new.status<>'posted' or new.amount<=0 or new.beneficiary_id is null then return new;end if;
 if tg_op='UPDATE' and old.status='posted' then return new;end if;
 v_snapshot:=private.current_bonus_wallet_routing();
 v_route_key:=private.ecommerce_bonus_wallet_route_key(new.reward_kind);
 v_target:=coalesce(v_snapshot->'routes'->>v_route_key,'proceed');
 insert into public.member_income_wallets(member_id) values(new.beneficiary_id)
 on conflict(member_id) do nothing;
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,source_reward_id,note,metadata,idempotency_key)
 values(new.beneficiary_id,v_target,new.amount,'ecommerce_earning',new.id,
 case when v_target='cash' then 'E-commerce earning routed to Cash Wallet' else 'E-commerce earning routed to Proceed Wallet' end,
 jsonb_build_object('reward_kind',new.reward_kind,'rate',new.rate,'order_id',new.order_id,
 'routing_key',v_route_key,'routing_version',v_snapshot->>'version','target_wallet',v_target),
 'ecommerce-route:'||new.id) on conflict(idempotency_key) do nothing;
 get diagnostics v_inserted_count=row_count;
 if v_inserted_count=1 and v_target='proceed' then
  update public.mio_wallet_accounts set balance=balance-new.amount,updated_at=now()
  where member_id=new.beneficiary_id and balance>=new.amount;
  if not found then raise exception 'E-commerce wallet routing reconciliation failed';end if;
  update public.member_income_wallets set proceed_mio=proceed_mio+new.amount,updated_at=now()
  where member_id=new.beneficiary_id;
 end if;
 return new;
end $function$;

revoke all on function public.admin_bonus_wallet_routing() from public,anon;
revoke all on function public.admin_set_bonus_wallet_routing(jsonb,integer) from public,anon;
grant execute on function public.admin_bonus_wallet_routing() to authenticated;
grant execute on function public.admin_set_bonus_wallet_routing(jsonb,integer) to authenticated;
