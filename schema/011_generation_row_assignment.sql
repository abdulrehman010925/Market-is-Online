CREATE OR REPLACE FUNCTION private.credit_activation_bonuses(p_activation_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  act public.package_activations%rowtype;
  direct_sponsor uuid;
  beneficiary uuid;
  receiver_activation public.package_activations%rowtype;
  recipient record;
  gen_depth integer;
  gen_limit integer;
  gen1_rate numeric(10,8);
  gen2_rate numeric(10,8) := 0.05;
  stack_gen1 boolean := false;
  applied integer := 0;
  txn_id uuid;
  payout numeric(18,4);
  rate numeric(10,8);
  key text;
begin
  select * into act from public.package_activations where id=p_activation_id;
  if act.id is null or act.status<>'approved' then return 0; end if;
  select (config_value->>'direct_and_gen1_stack')::boolean,
         coalesce((config_value->>'gen2_plus_rate')::numeric,0.05)
    into stack_gen1,gen2_rate
    from public.system_config where config_key='GENERATION' and effective_to is null
    order by version desc limit 1;
  stack_gen1 := coalesce(stack_gen1,false);
  gen2_rate := coalesce(gen2_rate,0.05);
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=act.member_id;

  if direct_sponsor is not null and exists(select 1 from public.member_profiles where user_id=direct_sponsor and status='active')
     and private.current_package_code(direct_sponsor) is not null then
    payout := round(act.bv*act.direct_rate,4);
    if payout>0 then
      key := 'direct:' || act.id::text;
      insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,qualifying_base,rate,gross_amount,
        payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
      values(direct_sponsor,'direct',act.id,act.bv,act.direct_rate,payout,payout,'MIO','phase1-direct-v1',
        jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'rate',act.direct_rate,'calculation','BV x direct rate'),
        'posted',key) on conflict(idempotency_key) do nothing returning id into txn_id;
      if txn_id is not null then
        update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=direct_sponsor;
        insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
          values(direct_sponsor,payout,'bonus_credit',act.id,txn_id,'Direct bonus','bonus:'||txn_id::text);
        applied := applied+1;
      end if;
    end if;
  end if;

  -- Loop over a bounded sponsor chain. Depth is capped by the configured maximum.
  for recipient in
    with recursive uplines(user_id,sponsor_id,depth,path) as (
      select m.user_id,m.sponsor_id,1,array[m.user_id] from public.member_profiles m where m.user_id=act.member_id
      union all
      select parent.user_id,parent.sponsor_id,u.depth+1,u.path||parent.user_id
        from uplines u join public.member_profiles parent on parent.user_id=u.sponsor_id
        where u.sponsor_id is not null and u.depth<10 and not parent.user_id=any(u.path)
    )
    select u.sponsor_id as member_id,u.depth as generation
      from uplines u where u.sponsor_id is not null order by u.depth
  loop
    beneficiary := recipient.member_id;
    gen_depth := recipient.generation;
    if not exists(select 1 from public.member_profiles where user_id=beneficiary and status='active') then continue; end if;
    select a.* into receiver_activation
      from public.package_activations a join public.package_versions pv
        on pv.package_code=a.package_code and pv.version=a.package_version
      where a.member_id=beneficiary and a.status='approved'
      order by a.base_value desc,a.activated_at desc nulls last,a.requested_at desc limit 1;
    select pv.max_generations,pv.generation1_rate into gen_limit,gen1_rate
      from public.package_versions pv where pv.package_code=receiver_activation.package_code
        and pv.version=receiver_activation.package_version;
    if receiver_activation.id is null or gen_depth>gen_limit then continue; end if;
    if gen_depth=1 and not stack_gen1 then continue; end if;
    rate := case when gen_depth=1 then gen1_rate else gen2_rate end;
    payout := round(act.bv*rate,4);
    if payout<=0 then continue; end if;
    key := 'generation:'||act.id::text||':'||beneficiary::text||':'||gen_depth::text;
    insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,
      gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
    values(beneficiary,'generation',act.id,gen_depth,act.bv,rate,payout,payout,'MIO','phase1-generation-v1',
      jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'beneficiary_package',receiver_activation.package_code,
        'generation',gen_depth,'rate',rate,'direct_gen1_stack',stack_gen1), 'posted',key)
    on conflict(idempotency_key) do nothing returning id into txn_id;
    if txn_id is not null then
      update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=beneficiary;
      insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
        values(beneficiary,payout,'bonus_credit',act.id,txn_id,'Generation bonus','bonus:'||txn_id::text);
      applied := applied+1;
    end if;
  end loop;
  return applied;
end;
$function$;
