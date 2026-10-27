-- Track Binary Rank Points (BRP) by permanent LEFT/RIGHT binary ancestry.
-- Each activation keeps the BRP value snapshotted on that activation, so a
-- temporary BRP promotion affects only activations created while it is live.

alter table public.point_ledger drop constraint if exists point_ledger_check;
alter table public.point_ledger drop constraint if exists point_ledger_side_by_type_check;
alter table public.point_ledger add constraint point_ledger_side_by_type_check check (
  (point_type = 'BP' and side is not null)
  or point_type = 'BRP'
  or (point_type not in ('BP', 'BRP') and side is null)
);

create or replace function private.credit_binary_volume(p_activation_id uuid)
returns integer language plpgsql security definer set search_path to '' as $function$
declare
  act public.package_activations%rowtype;
  current_member uuid;
  parent_member uuid;
  member_side text;
  depth integer := 0;
  credited integer := 0;
begin
  select * into act from public.package_activations
  where id = p_activation_id and status = 'approved';
  if act.id is null or (act.bp <= 0 and act.brp <= 0) or act.source = 'SHOPPING_PPV' then
    return 0;
  end if;
  current_member := act.member_id;
  loop
    select parent_id, side into parent_member, member_side
    from public.binary_placements where member_id = current_member;
    exit when parent_member is null;
    if act.bp <> 0 then
      insert into public.point_ledger(member_id,point_type,amount,side,source_activation_id,entry_kind,idempotency_key)
      values(parent_member,'BP',act.bp,member_side,act.id,'credit','bp:'||act.id::text||':'||parent_member::text)
      on conflict(idempotency_key) do nothing;
      if found then credited := credited + 1; end if;
    end if;
    if act.brp <> 0 then
      insert into public.point_ledger(member_id,point_type,amount,side,source_activation_id,entry_kind,idempotency_key)
      values(parent_member,'BRP',act.brp,member_side,act.id,'credit','brp-network:'||act.id::text||':'||parent_member::text)
      on conflict(idempotency_key) do nothing;
    end if;
    current_member := parent_member;
    depth := depth + 1;
    if depth >= 100 then raise exception 'Binary placement depth limit reached'; end if;
  end loop;
  return credited;
end
$function$;
revoke all on function private.credit_binary_volume(uuid) from public, anon, authenticated;

-- Rebuild historical side totals from each immutable activation snapshot.
insert into public.point_ledger(member_id,point_type,amount,side,source_activation_id,entry_kind,idempotency_key,created_at)
select bp.member_id,'BRP',a.brp,bp.side,bp.source_activation_id,bp.entry_kind,
  'brp-network:'||bp.source_activation_id::text||':'||bp.member_id::text,bp.created_at
from public.point_ledger bp
join public.package_activations a on a.id = bp.source_activation_id
where bp.point_type = 'BP' and bp.source_activation_id is not null and a.brp <> 0
on conflict(idempotency_key) do nothing;

create or replace function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  result jsonb;
  root uuid;
  parent jsonb;
  weighted_nodes jsonb;
  share_points numeric;
begin
  result := public.my_network_before_vendor_root(p_kind,p_root_code,p_depth);
  if p_kind = 'vendor' then
    root := auth.uid();
    if nullif(trim(p_root_code),'') is not null then
      select user_id into root from public.member_profiles
      where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');
    end if;
    select jsonb_build_object('id',user_id,'parent_id',null,'full_name',full_name,'member_code',member_code,
      'depth',0,'package',private.current_package_code(user_id),'rank',achieved_rank,'status',status)
    into parent from public.member_profiles where user_id=root;
    result:=jsonb_set(result,'{nodes}',jsonb_build_array(parent)||coalesce(result->'nodes','[]'::jsonb));
  end if;
  share_points:=coalesce((private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,50);
  select coalesce(jsonb_agg(n.node||jsonb_build_object(
    'binary_share_points_each_side',share_points,
    'binary_entitlement',coalesce(s.binary_entitlement,0),
    'binary_entitlement_percent',coalesce(s.binary_entitlement,0)*100,
    'raw_binary_shares',case when share_points>0 then trunc(least(coalesce(s.left_available,0),coalesce(s.right_available,0))/share_points,1) else 0 end,
    'available_binary_shares',coalesce(s.completed_shares,0),
    'left_brp',coalesce(r.left_brp,0),'right_brp',coalesce(r.right_brp,0),
    'total_left_brp',coalesce(r.left_brp,0),'total_right_brp',coalesce(r.right_brp,0)
  ) order by n.ordinality),'[]'::jsonb) into weighted_nodes
  from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality as n(node,ordinality)
  left join private.binary_live_shares(clock_timestamp()) s on s.member_id=nullif(n.node->>'id','')::uuid
  left join (
    select member_id,
      coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='LEFT'),0) left_brp,
      coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='RIGHT'),0) right_brp
    from public.point_ledger where point_type='BRP' and side is not null group by member_id
  ) r on r.member_id=nullif(n.node->>'id','')::uuid;
  return jsonb_set(result,'{nodes}',weighted_nodes);
end
$function$;
revoke all on function public.my_network(text,text,integer) from public, anon;
grant execute on function public.my_network(text,text,integer) to authenticated;
notify pgrst, 'reload schema';
