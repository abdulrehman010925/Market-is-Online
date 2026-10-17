create or replace function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); root uuid; is_company boolean; allowed boolean; result jsonb; root_depth integer:=0; view_depth integer; begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status='active') then raise exception 'Active account required'; end if;
 is_company:=private.has_role('admin'); root:=uid;
 if p_kind not in('generation','binary','pool','single_line','vendor') or p_depth is null or p_depth<0 or (not is_company and p_depth not between 1 and 10) then raise exception 'Invalid tree view'; end if;
 view_depth:=case when p_depth=0 then (select count(*)::integer from public.member_profiles) else p_depth end;
 if is_company and p_kind in('binary','pool','single_line') then select founder_id into root from private.network_foundation where company_id=uid; end if;
 if nullif(trim(p_root_code),'') is not null then
  select user_id into root from public.member_profiles where member_code=upper(trim(p_root_code));

 end if;
 if not is_company then
  with recursive team(id,depth,path) as (
   select uid,0,array[uid]
   union all select m.user_id,t.depth+1,t.path||m.user_id from team t join public.member_profiles m on
    (p_kind in('generation','vendor') and m.sponsor_id=t.id) or
    (p_kind not in('generation','vendor') and exists(select 1 from public.binary_placements b where b.member_id=m.user_id and b.parent_id=t.id))
   where t.depth<10 and not m.user_id=any(t.path)
  ) select min(depth) into root_depth from team where id=root;
  if root_depth is null then raise exception 'Your network is limited to 10 levels'; end if;
  view_depth:=least(view_depth,10-root_depth);
 end if;
 if root is null then return jsonb_build_object('nodes','[]'::jsonb); end if;
 if p_kind='vendor' then
  return jsonb_build_object('nodes',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'parent_id',root,'full_name',v.business_name,'member_code',m.member_code,'depth',1,'commission_rate',v.commission_rate,'status',v.status)) from public.vendors v join public.member_profiles m on m.user_id=v.owner_user_id where m.sponsor_id=root),'[]'::jsonb));
 end if;
 with recursive tree(id,parent_id,side,depth,path) as (
  select root,null::uuid,null::text,0,array[root]
  union all select m.user_id, t.id,case when p_kind='generation' then null else b.side end,t.depth+1,t.path||m.user_id from tree t join public.member_profiles m on
   (p_kind='generation' and m.sponsor_id=t.id) or (p_kind<>'generation' and exists(select 1 from public.binary_placements x where x.member_id=m.user_id and x.parent_id=t.id))
   left join public.binary_placements b on b.member_id=m.user_id where t.depth<view_depth and not m.user_id=any(t.path)
 ), bounded as(select * from tree order by depth,id limit 501)
 select jsonb_build_object('root_depth',root_depth,'visible_levels',view_depth,'truncated',count(*)>500,'nodes',coalesce(jsonb_agg(jsonb_build_object('id',t.id,'parent_id',t.parent_id,'side',t.side,'depth',t.depth,'member_code',m.member_code,'full_name',m.full_name,'status',m.status,'package',private.current_package_code(t.id),
 'bp',coalesce((select bp from public.package_activations a where a.member_id=t.id and a.status='approved' order by base_value desc,activated_at desc limit 1),0),
 'left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT'),0)-coalesce((select sum(consumed_left) from public.binary_member_results where member_id=t.id),0),
 'right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT'),0)-coalesce((select sum(consumed_right) from public.binary_member_results where member_id=t.id),0)) order by t.depth,t.side,t.id) filter(where t.id in(select id from bounded limit 500)),'[]'::jsonb)) into result from bounded t join public.member_profiles m on m.user_id=t.id;
 return result;
end $$;
