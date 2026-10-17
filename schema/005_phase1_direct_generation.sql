-- Direct and Generation payouts use the source activation BV and the package
-- rates in the activation snapshot. They credit MIO Points through the ledger.

alter table public.mio_ledger add column if not exists bonus_transaction_id uuid references public.bonus_transactions(id);
alter table public.mio_ledger drop constraint if exists mio_ledger_action_check;
alter table public.mio_ledger add constraint mio_ledger_action_check
  check (action in ('admin_mint','admin_burn','transfer_in','transfer_out','package_activation','bonus_credit'));
alter table public.mio_ledger drop constraint if exists mio_ledger_amount_check;
alter table public.mio_ledger add constraint mio_ledger_amount_check
  check ((action in ('admin_mint','transfer_in','bonus_credit') and amount > 0)
    or (action in ('admin_burn','transfer_out','package_activation') and amount < 0));
alter table public.mio_ledger drop constraint if exists mio_ledger_check2;
alter table public.mio_ledger drop constraint if exists mio_ledger_check1;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check
  check ((action in ('package_activation','bonus_credit') and activation_id is not null)
    or (action not in ('package_activation','bonus_credit') and activation_id is null));

create function private.credit_activation_bonuses(p_activation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
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
    select a into receiver_activation
      from public.package_activations a join public.package_versions pv
        on pv.package_code=a.package_code and pv.version=a.package_version
      where a.member_id=beneficiary and a.status='approved'
      order by a.activated_at desc nulls last,a.requested_at desc limit 1;
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
$$;
revoke all on function private.credit_activation_bonuses(uuid) from public, anon, authenticated;

create or replace function private.activate_next_ppv_package(p_member_id uuid, p_order_id uuid, p_cumulative_ppv numeric)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  rank_code text[] := array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2'];
  current_code text := private.current_package_code(p_member_id);
  current_rank integer := array_position(rank_code,current_code);
  i integer;
  p public.package_versions%rowtype;
  aid uuid;
  count_activated integer := 0;
  id_key text;
begin
  -- Premium never auto-activates or auto-upgrades through PPV.
  if current_code='PREMIUM' then return 0; end if;
  if current_rank is null then current_rank := 0; end if;
  for i in current_rank+1..4 loop
    select * into p from public.package_versions where package_code=rank_code[i] and is_active
      and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
    if p.package_code is null or p_cumulative_ppv < p.ppv then exit; end if;
    id_key := 'ppv:' || p_order_id::text || ':' || rank_code[i];
    if exists(select 1 from public.package_activations where idempotency_key=id_key) then continue; end if;
    aid := gen_random_uuid();
    insert into public.package_activations(
      id,member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,
      direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
    values(aid,p_member_id,p.package_code,p.version,'SHOPPING_PPV',p_order_id::text,p.base_value,p.company_fee,p.payable_price,
      p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
      'approved',now(),null,id_key);
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values(p_member_id,'PPV',p.ppv,aid,'credit',id_key || ':ppv');
    perform private.credit_activation_bonuses(aid);
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(p_member_id,'PACKAGE_AUTO_ACTIVATED_PPV','package_activation',aid,
        jsonb_build_object('order_id',p_order_id,'package_code',p.package_code,'ppv_balance',p_cumulative_ppv));
    count_activated := count_activated+1;
  end loop;
  return count_activated;
end;
$$;
revoke all on function private.activate_next_ppv_package(uuid,uuid,numeric) from public, anon, authenticated;

create or replace function public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  member uuid := (select auth.uid());
  p public.package_versions%rowtype;
  current_code text;
  current_price numeric(14,2);
  activation uuid := gen_random_uuid();
  new_balance numeric(20,4);
begin
  if member is null then raise exception 'Authentication required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  if not exists(select 1 from public.member_profiles where user_id=member and status='active') then
    raise exception 'Active member account required';
  end if;
  select * into p from public.package_versions where package_code=p_package_code and is_active
    and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
  if p.package_code is null then raise exception 'Package not available'; end if;
  current_code := private.current_package_code(member);
  if current_code is not null then
    select payable_price into current_price from public.package_versions where package_code=current_code order by version desc limit 1;
    if p.payable_price <= coalesce(current_price,0) then raise exception 'Choose a higher package tier'; end if;
  end if;
  update public.mio_wallet_accounts set balance=balance-p.payable_price, updated_at=now()
    where member_id=member and balance >= p.payable_price returning balance into new_balance;
  if new_balance is null then raise exception 'Insufficient MIO Points'; end if;
  insert into public.package_activations(
    id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,
    base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,
    status,activated_at,approved_by,idempotency_key)
  values(activation,member,p.package_code,p.version,'MIO_POINTS',p_idempotency_key,'MIO',p.payable_price,1,
    p.base_value,p.company_fee,p.payable_price,p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
    'approved',now(),member,p_idempotency_key);
  insert into public.mio_ledger(member_id,amount,action,activation_id,idempotency_key)
    values(member,-p.payable_price,'package_activation',activation,p_idempotency_key || ':mio');
  insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
    values(member,'PPV',p.ppv,activation,'credit',p_idempotency_key || ':ppv');
  perform private.credit_activation_bonuses(activation);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,jsonb_build_object('package_code',p.package_code,'payable_mio',p.payable_price,'ppv_credited',p.ppv));
  return activation;
end;
$$;
revoke all on function public.activate_package_with_mio(text,text) from public, anon;
grant execute on function public.activate_package_with_mio(text,text) to authenticated;

-- Backfill no rows: there have been no member package activations yet.
