insert into public.system_config(config_key,version,config_value,effective_from)
values('MARKETPLACE_ANNOUNCEMENTS',1,'[]'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_marketplace_announcements(p_announcements jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v integer; item jsonb;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if jsonb_typeof(p_announcements)<>'array' or jsonb_array_length(p_announcements)>10 then
   raise exception 'Save up to ten visitor notices';
 end if;
 for item in select value from jsonb_array_elements(p_announcements) loop
   if jsonb_typeof(item)<>'object'
      or coalesce(item->>'cadence','') not in ('daily','weekly','monthly')
      or coalesce(item->>'kind','') not in ('text','image','video')
      or length(coalesce(item->>'title',''))>100
      or length(coalesce(item->>'body',''))>1000
      or coalesce((item->>'enabled')::boolean,false) is null then
     raise exception 'Notice fields are not valid';
   end if;
   if coalesce((item->>'enabled')::boolean,false) and coalesce(item->>'title','')='' then
     raise exception 'Enabled notices need a title';
   end if;
   if item->>'kind' in ('image','video') and coalesce(item->>'media_url','') !~ '^https://' then
     raise exception 'Image or video notices need a public HTTPS media URL';
   end if;
 end loop;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_ANNOUNCEMENTS';
 update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_ANNOUNCEMENTS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('MARKETPLACE_ANNOUNCEMENTS',v,p_announcements,clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'MARKETPLACE_ANNOUNCEMENTS_SAVED','system_config',jsonb_build_object('version',v,'count',jsonb_array_length(p_announcements)));
 return jsonb_build_object('version',v,'count',jsonb_array_length(p_announcements));
end $$;
revoke all on function public.admin_set_marketplace_announcements(jsonb) from public,anon;
grant execute on function public.admin_set_marketplace_announcements(jsonb) to authenticated;

do $$begin
 if to_regclass('storage.buckets') is not null then
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
   values('site-announcements','site-announcements',true,26214400,array['image/jpeg','image/png','image/webp','video/mp4','video/webm'])
   on conflict(id) do update set public=true,file_size_limit=26214400,allowed_mime_types=array['image/jpeg','image/png','image/webp','video/mp4','video/webm'];
  execute 'drop policy if exists site_announcements_public_read on storage.objects';
  execute 'create policy site_announcements_public_read on storage.objects for select using(bucket_id=''site-announcements'')';
  execute 'drop policy if exists site_announcements_admin_insert on storage.objects';
  execute 'create policy site_announcements_admin_insert on storage.objects for insert to authenticated with check(bucket_id=''site-announcements'' and private.has_role(''admin''))';
  execute 'drop policy if exists site_announcements_admin_update on storage.objects';
  execute 'create policy site_announcements_admin_update on storage.objects for update to authenticated using(bucket_id=''site-announcements'' and private.has_role(''admin'')) with check(bucket_id=''site-announcements'' and private.has_role(''admin''))';
  execute 'drop policy if exists site_announcements_admin_delete on storage.objects';
  execute 'create policy site_announcements_admin_delete on storage.objects for delete to authenticated using(bucket_id=''site-announcements'' and private.has_role(''admin''))';
 end if;
end $$;
