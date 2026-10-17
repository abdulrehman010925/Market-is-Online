-- Binary placement and 35% weekly Binary Pool Share.
-- Qualification for pool participation is an active package plus a completed
-- 50-left/50-right share. A weekly cycle is created and closed by an admin.

alter table public.mio_ledger add column if not exists cycle_id uuid references public.binary_cycles(id);
alter table public.mio_ledger drop constraint if exists mio_ledger_activation_source_check;
alter table public.mio_ledger add constraint mio_ledger_bonus_source_check
  check ((action='package_activation' and activation_id is not null and bonus_transaction_id is null and cycle_id is null)
    or (action='bonus_credit' and bonus_transaction_id is not null
      and ((activation_id is not null and cycle_id is null) or (activation_id is null and cycle_id is not null)))
    or (action not in ('package_activation','bonus_credit') and activation_id is null and bonus_transaction_id is null and cycle_id is null));

create function private.credit_binary_volume(p_activation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  act public.package_activations%rowtype;
  current_member uuid;
  parent_member uuid;
  member_side text;
  depth integer := 0;
  credited integer := 0;
begin
  select * into act from public.package_activations where id=p_activation_id and status='approved';
  if act.id is null or act.bp<=0 then return 0; end if;
  current_member := act.member_id;
  loop
    select parent_id,side into parent_member,member_side from public.binary_placements where member_id=current_member;
    exit when parent_member is null;
    insert into public.point_ledger(member_id,point_type,amount,side,source_activation_id,entry_kind,idempotency_key)
      values(parent_member,'BP',act.bp,member_side,act.id,'credit',
        'bp:'||act.id::text||':'||parent_member::text)
      on conflict(idempotency_key) do nothing;
    if found then credited := credited+1; end if;
    current_member := parent_member;
    depth := depth+1;
    if depth>=100 then raise exception 'Binary placement depth limit reached'; end if;
  end loop;
  return credited;
end;
$$;
revoke all on function private.credit_binary_volume(uuid) from public, anon, authenticated;

create function public.admin_place_binary_member(p_member_code text, p_parent_code text, p_side text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  member uuid;
  parent uuid;
  activation_id uuid;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select user_id into member from public.member_profiles
    where upper(member_code)=upper(trim(p_member_code)) or upper(referral_code)=upper(trim(p_member_code)) limit 1;
  if member is null then raise exception 'Member code not found'; end if;
  if exists(select 1 from public.binary_placements where member_id=member) then raise exception 'Member already has a binary placement'; end if;
  if nullif(trim(coalesce(p_parent_code,'')),'') is null then
    if p_side is not null and trim(p_side)<>'' then raise exception 'Root placement has no side'; end if;
    if exists(select 1 from public.binary_placements where parent_id is null) then raise exception 'A binary root already exists'; end if;
    insert into public.binary_placements(member_id,parent_id,side,placed_by) values(member,null,null,admin_id);
  else
    select user_id into parent from public.member_profiles
      where upper(member_code)=upper(trim(p_parent_code)) or upper(referral_code)=upper(trim(p_parent_code)) limit 1;
    if parent is null then raise exception 'Parent code not found'; end if;
    if parent=member then raise exception 'A member cannot be placed under themselves'; end if;
    if not exists(select 1 from public.binary_placements where member_id=parent) then raise exception 'Place the parent before placing a child'; end if;
    if upper(trim(coalesce(p_side,''))) not in ('LEFT','RIGHT') then raise exception 'Choose LEFT or RIGHT'; end if;
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
      values(member,parent,upper(trim(p_side)),admin_id);
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'BINARY_MEMBER_PLACED','binary_placement',member,
      jsonb_build_object('parent_id',parent,'side',upper(nullif(trim(p_side),''))));
  -- If package activation preceded placement, now backfill this member's BP.
  for activation_id in select id from public.package_activations where member_id=member and status='approved' loop
    perform private.credit_binary_volume(activation_id);
  end loop;
  return member;
end;
$$;
revoke all on function public.admin_place_binary_member(text,text,text) from public, anon;
grant execute on function public.admin_place_binary_member(text,text,text) to authenticated;

create function public.admin_close_binary_cycle(p_cycle_code text, p_starts_at timestamptz, p_ends_at timestamptz, p_timezone text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  cycle uuid := gen_random_uuid();
  eligible numeric(18,4);
  pool numeric(18,8);
  share_count bigint;
  m record;
  previous_left numeric(18,4);
  previous_right numeric(18,4);
  new_left numeric(18,4);
  new_right numeric(18,4);
  shares bigint;
  gross numeric(18,8);
  member_pay numeric(18,8);
  retention numeric(18,8);
  txn uuid;
  key text;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at then
    raise exception 'A cycle code and valid start/end are required';
  end if;
  if exists(select 1 from public.binary_cycles c where c.status not in ('reversed')
    and c.starts_at<p_ends_at and c.ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
  if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;

  select coalesce(sum(base_value),0) into eligible from public.package_activations
    where status='approved' and activated_at>=p_starts_at and activated_at<p_ends_at;
  pool := round(eligible*0.35,8);
  insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
    values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,trim(coalesce(p_timezone,'Asia/Karachi')),eligible,0.35,pool,'open');

  -- First pass counts full 50/50 shares after the latest earlier carry.
  with active_package as (
    select distinct on (a.member_id) a.member_id,a.package_code,a.package_version,pv.binary_entitlement
      from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version
      join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
      where a.status='approved' and a.activated_at<p_ends_at
      order by a.member_id,a.activated_at desc nulls last,a.requested_at desc
  ), prior as (
    select ap.member_id,
      coalesce((select r.carry_left from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
        where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) left_carry,
      coalesce((select r.carry_right from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
        where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) right_carry
    from active_package ap
  ), volume as (
    select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) left_new,
      coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) right_new
    from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
    where pl.point_type='BP' and a.status='approved' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at
    group by pl.member_id
  )
  select coalesce(sum(floor(least(pr.left_carry+coalesce(v.left_new,0),pr.right_carry+coalesce(v.right_new,0))/50)::bigint),0)
    into share_count from prior pr left join volume v on v.member_id=pr.member_id;

  if share_count=0 then
    update public.binary_cycles set total_completed_shares=0,status='unallocated',closed_at=now() where id=cycle;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'pool',pool,'shares',0));
    return cycle;
  end if;
  update public.binary_cycles set total_completed_shares=share_count,gross_share_value=pool/share_count,status='frozen' where id=cycle;

  for m in
    with active_package as (
      select distinct on (a.member_id) a.member_id,a.package_code,a.package_version,pv.binary_entitlement
        from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version
        join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
        where a.status='approved' and a.activated_at<p_ends_at
        order by a.member_id,a.activated_at desc nulls last,a.requested_at desc
    ), prior as (
      select ap.*,
        coalesce((select r.carry_left from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
          where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) left_carry,
        coalesce((select r.carry_right from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
          where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) right_carry
      from active_package ap
    ), volume as (
      select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) left_new,
        coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) right_new
      from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
      where pl.point_type='BP' and a.status='approved' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at
      group by pl.member_id
    ), balances as (
      select pr.member_id,pr.package_code,pr.package_version,pr.binary_entitlement,
        pr.left_carry+coalesce(v.left_new,0) left_available,pr.right_carry+coalesce(v.right_new,0) right_available
      from prior pr left join volume v on v.member_id=pr.member_id
    )
    select *,floor(least(left_available,right_available)/50)::bigint completed from balances
  loop
    shares := m.completed;
    gross := round((pool/share_count)*shares,8);
    member_pay := round(gross*m.binary_entitlement,4);
    retention := gross-member_pay;
    insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,
      completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,
      qualification_snapshot)
    values(cycle,m.member_id,m.package_code,m.package_version,m.left_available,m.right_available,shares,m.binary_entitlement,
      gross,member_pay,retention,shares*50,shares*50,m.left_available-(shares*50),m.right_available-(shares*50),
      jsonb_build_object('qualification','active_package_and_full_share','pool_rate',0.35,'share_points_each_side',50));
    if member_pay>0 then
      key := 'binary:'||cycle::text||':'||m.member_id::text;
      insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,
        currency,formula_version,calculation_trace,status,idempotency_key)
      values(m.member_id,'binary_pool_share',cycle,gross,m.binary_entitlement,gross,member_pay,'MIO','phase1-binary-pool-v1',
        jsonb_build_object('completed_shares',shares,'entitlement',m.binary_entitlement,'gross_share_value',pool/share_count,
          'member_amount',member_pay,'company_retention',retention), 'posted',key)
      on conflict(idempotency_key) do nothing returning id into txn;
      if txn is not null then
        update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
        insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)
          values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
      end if;
    end if;
  end loop;
  update public.binary_cycles set status='posted',closed_at=now() where id=cycle;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,
      jsonb_build_object('eligible_base',eligible,'pool_rate',0.35,'pool',pool,'completed_shares',share_count,'gross_share_value',pool/share_count));
  return cycle;
end;
$$;
revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) from public, anon;
grant execute on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) to authenticated;

create function private.on_package_activation_binary_volume()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status='approved' then perform private.credit_binary_volume(new.id); end if;
  return new;
end;
$$;
revoke all on function private.on_package_activation_binary_volume() from public, anon, authenticated;
create trigger package_activation_binary_volume
after insert on public.package_activations for each row execute function private.on_package_activation_binary_volume();

