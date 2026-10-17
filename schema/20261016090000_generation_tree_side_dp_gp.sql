-- Show actual DP and GP volume under each permanent binary placement side.
create or replace function private.binary_side_dp_gp_totals(p_member uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
 with recursive downline(id,root_side,path) as (
  select b.member_id,b.side,array[p_member,b.member_id]
  from public.binary_placements b
  where b.parent_id=p_member
  union all
  select b.member_id,d.root_side,d.path||b.member_id
  from downline d
  join public.binary_placements b on b.parent_id=d.id
  where not b.member_id=any(d.path)
 ), totals as (
  select
   d.root_side,
   coalesce(sum(pl.amount) filter(where pl.point_type='DP'),0) as dp,
   coalesce(sum(pl.amount) filter(where pl.point_type='GP'),0) as gp
  from downline d
  left join public.point_ledger pl
   on pl.member_id=d.id
   and pl.created_at>private.financial_reset_at()
  group by d.root_side
 )
 select jsonb_build_object(
  'left_dp',coalesce((select dp from totals where root_side='LEFT'),0),
  'right_dp',coalesce((select dp from totals where root_side='RIGHT'),0),
  'left_gp',coalesce((select gp from totals where root_side='LEFT'),0),
  'right_gp',coalesce((select gp from totals where root_side='RIGHT'),0)
 );
$$;

revoke all on function private.binary_side_dp_gp_totals(uuid) from public,anon,authenticated;

do $$
declare
 f text;
 old_fragment text;
 new_fragment text;
begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 old_fragment:='''right_team_count'',coalesce((private.binary_team_counts(t.id)->>''right'')::integer,0)';
 new_fragment:=old_fragment||
  ',''left_dp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''left_dp'')::numeric,0)'||
  ',''right_dp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''right_dp'')::numeric,0)'||
  ',''left_gp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''left_gp'')::numeric,0)'||
  ',''right_gp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''right_gp'')::numeric,0)';
 if position(old_fragment in f)=0 then
  raise exception 'Expected graphical tree team-count fragment was not found';
 end if;
 f:=replace(f,old_fragment,new_fragment);
 execute f;
end
$$;

notify pgrst,'reload schema';
