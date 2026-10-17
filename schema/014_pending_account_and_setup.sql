-- Dashboard account creation does not grant privileges. Only an explicit,
-- server-authorised finalisation can grant the operations role.
create or replace function private.create_member_profile()
returns trigger language plpgsql security definer set search_path='' as $$
declare sponsor uuid; ref text; nm text; ph text; pending boolean; reserved boolean;
begin
 reserved:=lower(new.email)='m.shujaat1993@gmail.com';
 pending:=coalesce(to_jsonb(new)->'raw_app_meta_data'->>'provider','')='google' or reserved;
 nm:=nullif(trim(new.raw_user_meta_data->>'full_name'),'');ph:=nullif(trim(new.raw_user_meta_data->>'phone'),'');ref:=nullif(upper(trim(new.raw_user_meta_data->>'referral_code')),'');
 if not pending then
  if nm is null then raise exception 'Full name is required'; end if;
  if ph is null then raise exception 'Phone is required'; end if;
  if coalesce(new.raw_user_meta_data->>'terms_accepted','false')<>'true' then raise exception 'Terms consent is required'; end if;
  if ref is null then raise exception 'Referral code is required'; end if;
  select user_id into sponsor from public.member_profiles where (upper(referral_code)=ref or upper(member_code)=ref) and status='active';
  if sponsor is null or sponsor=new.id then raise exception 'Referral code not found'; end if;
 end if;
 ref:=upper(substr(replace(new.id::text,'-',''),1,10));
 insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,sponsor_id,status,terms_accepted_at,terms_version)
 values(new.id,'MIO-'||ref,ref,coalesce(nm,'Member'),ph,sponsor,case when pending then 'pending'::public.account_status else 'active'::public.account_status end,
 case when pending then null else now() end,case when pending then null else 'phase1-terms-v1' end);
 insert into public.user_roles(user_id,role) values(new.id,'member');
 if reserved then update private.operator_setup set user_id=new.id where email=lower(new.email) and user_id is null; end if;
 return new;
end $$;
create or replace function public.finish_operator_setup(p_user_id uuid)
returns void language plpgsql security definer set search_path='' as $$begin
 if not exists(select 1 from private.operator_setup s join auth.users u on u.id=s.user_id and lower(u.email)=s.email where s.user_id=p_user_id and nullif(to_jsonb(u)->>'email_confirmed_at','') is not null) then raise exception 'Verified designated account required'; end if;
 if exists(select 1 from public.user_roles where role='admin' and user_id<>p_user_id) then raise exception 'Operations account already exists'; end if;
 update public.member_profiles set status='active',full_name='Market is Online Operations',terms_accepted_at=now(),terms_version='phase1-terms-v1' where user_id=p_user_id;
 insert into public.user_roles(user_id,role) values(p_user_id,'admin') on conflict do nothing;
 insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,is_company_owned)
 values(p_user_id,'Market is Online','m.shujaat1993@gmail.com',null,'Market is Online company store','active',true) on conflict(owner_user_id) do nothing;
 update private.operator_setup set expires_at=now() where user_id=p_user_id;
end $$;
-- Pending identity providers cannot submit seller applications before joining.
drop policy "authenticated user submits one vendor application" on public.vendor_applications;
create policy "active member submits seller application" on public.vendor_applications for insert to authenticated with check(applicant_user_id=auth.uid() and exists(select 1 from public.member_profiles where user_id=auth.uid() and status='active'));
