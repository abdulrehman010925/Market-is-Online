-- Keep carry-forward BP separate from lifetime binary volume in the graphical tree.
do $$
declare
 f text;
 old_fragment text;
 new_fragment text;
begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 old_fragment:='''right_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''RIGHT''),0)-coalesce((select sum(consumed_right) from public.binary_member_results where member_id=t.id),0)';
 new_fragment:=old_fragment||
  ',''total_left_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''LEFT''),0)'||
  ',''total_right_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''RIGHT''),0)';
 if position(old_fragment in f)=0 then
  raise exception 'Expected binary point fragment was not found in my_network_before_vendor_root';
 end if;
 f:=replace(f,old_fragment,new_fragment);
 execute f;
end
$$;

notify pgrst,'reload schema';
