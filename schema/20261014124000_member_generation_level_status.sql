create or replace function public.my_generation_level_status()
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
 member uuid:=auth.uid();
 cfg jsonb;
 code text;
 plan jsonb;
 active_count integer:=0;
 dp_total numeric:=0;
 allowed_count integer:=0;
 unlocked_count integer:=0;
begin
 if member is null then raise exception 'Authentication required';end if;
 if not private.registered_member(member) then raise exception 'Member account required';end if;
 cfg:=private.current_mlm_rules();
 code:=private.current_package_code(member);
 if code is not null then
  plan:=cfg->'plans'->code;
  allowed_count:=coalesce((plan->>'max_generations')::integer,0);
  unlocked_count:=private.generation_levels_by_dp(member,cfg);
 end if;
 select active_directs,total_dp into active_count,dp_total from private.direct_dp_summary(member);
 return jsonb_build_object('package_code',code,'package_name',coalesce(plan->>'display_name','Free account'),'allowed_levels',allowed_count,'unlocked_levels',unlocked_count,'active_directs',coalesce(active_count,0),'working_dp',coalesce(dp_total,0),'rules_version',cfg->>'version');
end;
$$;
revoke all on function public.my_generation_level_status() from public,anon;
grant execute on function public.my_generation_level_status() to authenticated;
notify pgrst,'reload schema';
