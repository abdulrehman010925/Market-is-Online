alter table public.member_profiles add column if not exists terms_accepted_at timestamptz;
alter table public.member_profiles add column if not exists terms_version text;

create or replace function private.create_member_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  sponsor uuid;
  display_name text;
  ref_code text;
  input_ref text;
  phone_value text;
begin
  display_name := nullif(trim(new.raw_user_meta_data ->> 'full_name'), '');
  input_ref := nullif(upper(trim(new.raw_user_meta_data ->> 'referral_code')), '');
  phone_value := nullif(trim(new.raw_user_meta_data ->> 'phone'), '');
  if display_name is null then raise exception 'Full name is required'; end if;
  if phone_value is null then raise exception 'Phone is required'; end if;
  if coalesce(new.raw_user_meta_data ->> 'terms_accepted','false') <> 'true' then raise exception 'Terms consent is required'; end if;
  if input_ref is not null then
    select user_id into sponsor from public.member_profiles
      where (upper(referral_code)=input_ref or upper(member_code)=input_ref) and status='active' limit 1;
    if sponsor is null then raise exception 'Referral code not found'; end if;
    if sponsor=new.id then raise exception 'Self-referral is not allowed'; end if;
  end if;
  ref_code := upper(substr(replace(new.id::text, '-', ''), 1, 10));
  insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,country_code,sponsor_id,terms_accepted_at,terms_version)
    values(new.id,'MIO-'||ref_code,ref_code,display_name,phone_value,
      coalesce(nullif(upper(trim(new.raw_user_meta_data ->> 'country_code')),''),'PK'),sponsor,now(),
      coalesce(nullif(trim(new.raw_user_meta_data ->> 'terms_version'),''),'phase1-terms-v1'));
  insert into public.user_roles(user_id,role) values(new.id,'member');
  return new;
end;
$$;
revoke all on function private.create_member_profile() from public, anon, authenticated;

create function public.my_direct_referrals()
returns table(member_code text,full_name text,created_at timestamptz,status public.account_status)
language sql stable security definer set search_path = '' as $$
  select mp.member_code,mp.full_name,mp.created_at,mp.status
  from public.member_profiles mp where mp.sponsor_id=(select auth.uid())
  order by mp.created_at desc;
$$;
revoke all on function public.my_direct_referrals() from public, anon;
grant execute on function public.my_direct_referrals() to authenticated;
