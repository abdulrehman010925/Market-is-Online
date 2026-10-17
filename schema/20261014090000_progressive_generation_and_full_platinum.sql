-- Generation qualification is progressive and capped by the member's package:
-- 1 direct + 20 DP => 2 levels, ... 5 directs + 100 DP => 10 levels.
create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer
language sql stable security definer set search_path=''
as $$
 with plan as (
  select coalesce((p_cfg->'plans'->coalesce(private.current_package_code(p_member),'BASIC_1')->>'max_generations')::integer,0) package_levels
 ), d as (
  select * from private.direct_dp_summary(p_member)
 ), earned as (
  select case
   when active_directs>=5 and total_dp>=100 then 10
   when active_directs>=4 and total_dp>=80 then 8
   when active_directs>=3 and total_dp>=60 then 6
   when active_directs>=2 and total_dp>=40 then 4
   when active_directs>=1 and total_dp>=20 then 2
   else 0
  end levels
  from d
 )
 select least(plan.package_levels,earned.levels) from plan cross join earned;
$$;

-- Platinum is a fresh full-price activation even when a lower plan is active.
-- Other upgrades remain incremental.
create or replace function public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
 member uuid := (select auth.uid());
 p public.package_versions%rowtype;
 current_p public.package_versions%rowtype;
 current_code text;
 activation uuid;
 new_balance numeric(20,4);
 due_base numeric(14,2); due_fee numeric(14,2); due_payable numeric(14,2);
 due_ppv numeric(14,4); due_bv numeric(14,4); due_dp numeric(14,4);
 due_gp numeric(14,4); due_bp numeric(14,4); due_brp numeric(14,4);
begin
 if member is null then raise exception 'Authentication required';end if;
 if length(coalesce(p_idempotency_key,''))<12 then raise exception 'Invalid idempotency key';end if;
 if not exists(select 1 from public.member_profiles where user_id=member) then raise exception 'Member account required';end if;
 select * into p from public.package_versions where package_code=p_package_code and is_active
  and effective_from<=now() and (effective_to is null or effective_to>now()) order by version desc limit 1;
 if p.package_code is null then raise exception 'Package not available';end if;
 perform pg_advisory_xact_lock(hashtextextended('package-member:'||member::text,0));
 select id into activation from public.package_activations where member_id=member and idempotency_key=member::text||':'||p_idempotency_key;
 if activation is not null then return activation;end if;
 current_code:=private.current_package_code(member);
 if current_code is not null then
  select * into current_p from public.package_versions where package_code=current_code order by version desc limit 1;
  if p.payable_price<=coalesce(current_p.payable_price,0) then raise exception 'Choose a higher package tier';end if;
 end if;
 if p.package_code='PREMIUM' then
  due_base:=p.base_value;due_fee:=p.company_fee;due_payable:=p.payable_price;
  due_ppv:=p.ppv;due_bv:=p.bv;due_dp:=p.dp;due_gp:=p.gp;due_bp:=p.bp;due_brp:=p.brp;
 else
  due_base:=p.base_value-coalesce(current_p.base_value,0);
  due_fee:=p.company_fee-coalesce(current_p.company_fee,0);
  due_payable:=p.payable_price-coalesce(current_p.payable_price,0);
  due_ppv:=p.ppv-coalesce(current_p.ppv,0);due_bv:=p.bv-coalesce(current_p.bv,0);
  due_dp:=p.dp-coalesce(current_p.dp,0);due_gp:=p.gp-coalesce(current_p.gp,0);
  due_bp:=p.bp-coalesce(current_p.bp,0);due_brp:=p.brp-coalesce(current_p.brp,0);
 end if;
 if due_payable<=0 or due_base<=0 or due_ppv<=0 then raise exception 'Choose a higher package tier';end if;
 update public.mio_wallet_accounts set balance=balance-due_payable,updated_at=now()
  where member_id=member and balance>=due_payable returning balance into new_balance;
 if new_balance is null then raise exception 'Insufficient MIO Points';end if;
 activation:=gen_random_uuid();
 insert into public.package_activations(
  id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,
  base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,
  status,activated_at,approved_by,idempotency_key)
 values(activation,member,p.package_code,p.version,'MIO_POINTS',p_idempotency_key,'MIO',due_payable,1,
  due_base,due_fee,due_payable,due_ppv,due_bv,due_dp,due_gp,due_bp,due_brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
  'approved',now(),member,member::text||':'||p_idempotency_key);
 insert into public.mio_ledger(member_id,amount,action,activation_id,idempotency_key)
  values(member,-due_payable,'package_activation',activation,member::text||':'||p_idempotency_key||':mio');
 insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
  values(member,'PPV',due_ppv,activation,'credit',member::text||':'||p_idempotency_key||':ppv');
 perform private.credit_activation_bonuses(activation);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
  values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,
   jsonb_build_object('package_code',p.package_code,'upgrade_due_mio',due_payable,'ppv_credited',due_ppv,
    'previous_package',current_code,'full_price_platinum',p.package_code='PREMIUM'));
 return activation;
end;
$$;

revoke all on function private.generation_levels_by_dp(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.activate_package_with_mio(text,text) from public,anon;
grant execute on function public.activate_package_with_mio(text,text) to authenticated;
notify pgrst,'reload schema';
