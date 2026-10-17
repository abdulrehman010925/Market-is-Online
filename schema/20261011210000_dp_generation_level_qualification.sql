-- DP qualification: generation levels open only when package, direct-active count
-- and direct DP thresholds are all satisfied.

create or replace function private.direct_dp_summary(p_member uuid)
returns table(active_directs integer,total_dp numeric)
language sql stable security definer set search_path=''
as $$
 select
  count(distinct mp.user_id)::integer,
  coalesce(sum(a.dp),0)::numeric
 from public.member_profiles mp
 left join public.package_activations a on a.member_id=mp.user_id and a.status='approved'
 where mp.sponsor_id=p_member and mp.status='active';
$$;

create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer
language sql stable security definer set search_path=''
as $$
 with pkg as (
  select coalesce(private.current_package_code(p_member),'BASIC_1') code
 ), plan as (
  select coalesce((p_cfg->'plans'->pkg.code->>'max_generations')::integer,0) package_levels from pkg
 ), d as (
  select * from private.direct_dp_summary(p_member)
 ), gate as (
  select case
   when active_directs>=5 and total_dp>=100 then 10
   when active_directs>=4 and total_dp>=80 then 8
   when active_directs>=3 and total_dp>=60 then 6
   when active_directs>=2 and total_dp>=40 then 4
   when active_directs>=1 and total_dp>=20 then 2
   else 0
  end direct_dp_levels from d
 )
 select least((select package_levels from plan),(select direct_dp_levels from gate));
$$;

create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,private.package_eligible(u.id) eligible,private.generation_levels_by_dp(u.id,cfg) open_levels
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*coalesce((plan->>'direct_rate')::numeric,0)
       else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved
 where depth=1 or (eligible and depth<=open_levels);
$$;

revoke all on function private.direct_dp_summary(uuid),private.generation_levels_by_dp(uuid,jsonb),private.mlm_point_candidates(uuid,numeric,numeric,jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';
