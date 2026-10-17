-- Vendor applications can be paused publicly and are also guarded at the RPC.
insert into public.system_config(config_key,version,config_value,effective_from)
values('VENDOR_REGISTRATION',1,'true'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_vendor_registration(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_enabled is null then raise exception 'Choose whether seller applications are open or closed'; end if;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='VENDOR_REGISTRATION';
 update public.system_config set effective_to=clock_timestamp() where config_key='VENDOR_REGISTRATION' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('VENDOR_REGISTRATION',v,to_jsonb(p_enabled),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'VENDOR_REGISTRATION_SET','system_config',jsonb_build_object('enabled',p_enabled,'version',v));
 return jsonb_build_object('enabled',p_enabled,'version',v);
end $$;
revoke all on function public.admin_set_vendor_registration(boolean) from public,anon;
grant execute on function public.admin_set_vendor_registration(boolean) to authenticated;

-- Hiding the application page is only presentation; block direct RPC calls too.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.submit_vendor_application(text,text,text,text,text,numeric,text)'::regprocedure);
 f:=replace(f,E'begin\n if auth.uid() is null then',
   E'begin\n if coalesce((select config_value from public.system_config where config_key=''VENDOR_REGISTRATION'' and effective_to is null order by version desc limit 1),''true''::jsonb) <> ''true''::jsonb then raise exception ''Seller registration is currently closed''; end if;\n if auth.uid() is null then');
 if position('Seller registration is currently closed' in f)=0 then raise exception 'Could not add seller application availability guard'; end if;
 execute f;
end $$;
notify pgrst,'reload schema';
