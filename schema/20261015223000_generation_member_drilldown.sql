create or replace function public.my_generation_member_details(p_member_code text)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
 viewer_id uuid:=auth.uid();
 target_id uuid;
 cfg jsonb;
 target_code text;
 package_code text;
 package_name text;
 allowed_levels integer:=0;
 unlocked_levels integer:=0;
 v_active_directs integer:=0;
 v_working_dp numeric:=0;
 result jsonb;
begin
 if viewer_id is null or not private.registered_member(viewer_id) then
  raise exception 'Member account required';
 end if;

 target_code:='MIO-'||regexp_replace(upper(trim(coalesce(p_member_code,''))),'^MIO-','');
 select user_id into target_id from public.member_profiles where member_code=target_code;
 if target_id is null then raise exception 'Member not found'; end if;

 if not private.has_role('admin') and target_id<>viewer_id then
  if not exists(
   with recursive permitted(id,depth,path) as (
    select viewer_id,0,array[viewer_id]
    union all
    select m.user_id,p.depth+1,p.path||m.user_id
    from permitted p join public.member_profiles m on m.sponsor_id=p.id
    where p.depth<10 and not m.user_id=any(p.path)
   ) select 1 from permitted where id=target_id
  ) then raise exception 'Member is outside your permitted network'; end if;
 end if;

 cfg:=private.current_mlm_rules();
 package_code:=private.current_package_code(target_id);
 if package_code is not null then
  package_name:=coalesce(cfg->'plans'->package_code->>'display_name',package_code);
  allowed_levels:=coalesce((cfg->'plans'->package_code->>'max_generations')::integer,0);
  unlocked_levels:=private.generation_levels_by_dp(target_id,cfg);
 else
  package_name:='Free account';
 end if;
 select d.active_directs,d.total_dp into v_active_directs,v_working_dp from private.direct_dp_summary(target_id) d;

 with recursive descendants(id,parent_id,depth,path) as (
  select m.user_id,m.sponsor_id,1,array[target_id,m.user_id]
  from public.member_profiles m where m.sponsor_id=target_id
  union all
  select m.user_id,m.sponsor_id,d.depth+1,d.path||m.user_id
  from descendants d join public.member_profiles m on m.sponsor_id=d.id
  where d.depth<10 and not m.user_id=any(d.path)
 ), member_rows as (
  select d.depth,m.user_id,m.full_name,m.member_code,m.status,m.created_at,m.profile_photo_url,
   private.current_package_code(m.user_id) member_package
  from descendants d join public.member_profiles m on m.user_id=d.id
 ), generations as (
  select level,
   coalesce((select count(*) from member_rows r where r.depth=level),0)::integer member_count,
   coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.user_id,'full_name',r.full_name,'member_code',r.member_code,'status',r.status,
    'joined_at',r.created_at,'profile_photo_url',r.profile_photo_url,'package',r.member_package
   ) order by r.created_at,r.member_code) from member_rows r where r.depth=level),'[]'::jsonb) members
  from generate_series(1,10) level
 ), gp_total as (
  select coalesce(sum(a.gp),0)::numeric value
  from descendants d join public.package_activations a on a.member_id=d.id and a.status='approved'
  where coalesce(a.activated_at,a.requested_at)>private.financial_reset_at()
 )
 select jsonb_build_object(
  'package_code',package_code,'package_name',package_name,
  'allowed_generations',allowed_levels,'active_generations',unlocked_levels,
  'direct_count',(select count(*) from member_rows where depth=1),
  'active_direct_count',coalesce(v_active_directs,0),'direct_points',coalesce(v_working_dp,0),
  'tngp',(select value from gp_total),'total_generation_network',(select count(*) from member_rows),
  'directs',coalesce((select members from generations where level=1),'[]'::jsonb),
  'generations',(select jsonb_agg(jsonb_build_object(
   'level',level,'member_count',member_count,'unlocked',level<=unlocked_levels,
   'allowed',level<=allowed_levels,'members',members
  ) order by level) from generations)
 ) into result;
 return result;
end;
$$;

revoke all on function public.my_generation_member_details(text) from public,anon;
grant execute on function public.my_generation_member_details(text) to authenticated;
notify pgrst,'reload schema';
