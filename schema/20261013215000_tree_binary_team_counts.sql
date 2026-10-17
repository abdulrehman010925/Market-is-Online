-- Add permanent LEFT and RIGHT binary downline counts to graphical tree nodes.
create or replace function private.binary_team_counts(p_member uuid)
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
 )
 select jsonb_build_object(
  'left',count(*) filter(where root_side='LEFT'),
  'right',count(*) filter(where root_side='RIGHT')
 )
 from downline;
$$;

revoke all on function private.binary_team_counts(uuid) from public,anon,authenticated;

do $$
declare
 f text;
 old_fragment text;
 new_fragment text;
begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 old_fragment:='''total_right_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''RIGHT'' and created_at>cutoff),0)';
 new_fragment:=old_fragment||
  ',''left_team_count'',coalesce((private.binary_team_counts(t.id)->>''left'')::integer,0)'||
  ',''right_team_count'',coalesce((private.binary_team_counts(t.id)->>''right'')::integer,0)';
 if position(old_fragment in f)=0 then
  raise exception 'Expected graphical tree total BP fragment was not found';
 end if;
 f:=replace(f,old_fragment,new_fragment);
 execute f;
end
$$;

notify pgrst,'reload schema';
