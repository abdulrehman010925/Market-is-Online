alter table public.member_profiles
  add column if not exists profile_photo_url text;
grant update(profile_photo_url) on public.member_profiles to authenticated;

do $$begin
 if to_regclass('storage.buckets') is not null then
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
   values('member-profile-photos','member-profile-photos',true,5242880,array['image/jpeg','image/png','image/webp'])
   on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
  execute 'drop policy if exists member_profile_photos_public_read on storage.objects';
  execute 'create policy member_profile_photos_public_read on storage.objects for select using(bucket_id=''member-profile-photos'')';
  execute 'drop policy if exists member_profile_photos_owner_insert on storage.objects';
  execute 'create policy member_profile_photos_owner_insert on storage.objects for insert to authenticated with check(bucket_id=''member-profile-photos'' and (storage.foldername(name))[1]=auth.uid()::text)';
  execute 'drop policy if exists member_profile_photos_owner_update on storage.objects';
  execute 'create policy member_profile_photos_owner_update on storage.objects for update to authenticated using(bucket_id=''member-profile-photos'' and (storage.foldername(name))[1]=auth.uid()::text) with check(bucket_id=''member-profile-photos'' and (storage.foldername(name))[1]=auth.uid()::text)';
 end if;
end $$;

