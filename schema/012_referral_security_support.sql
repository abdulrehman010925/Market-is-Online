-- Genuine operational account registry; no credentials are stored here.
create table private.operator_setup(email text primary key,user_id uuid unique,expires_at timestamptz not null);
insert into private.operator_setup values('m.shujaat1993@gmail.com',null,now()+interval '1 day');
revoke all on private.operator_setup from public,anon,authenticated;
alter table public.vendors alter column contact_phone drop not null;

create or replace function private.create_member_profile()
returns trigger language plpgsql security definer set search_path='' as $$
declare sponsor uuid; ref text; nm text; ph text; pending boolean; operator boolean;
begin
 operator:=exists(select 1 from private.operator_setup where email=lower(new.email) and user_id is null and expires_at>now()) and coalesce(to_jsonb(new)->'raw_app_meta_data'->>'operator_setup','false')='true';
 if lower(new.email)='m.shujaat1993@gmail.com' and not operator then raise exception 'This account is reserved'; end if;
 pending:=coalesce(to_jsonb(new)->'raw_app_meta_data'->>'provider','')='google' and not operator;
 nm:=nullif(trim(new.raw_user_meta_data->>'full_name'),'');
 ph:=nullif(trim(new.raw_user_meta_data->>'phone'),'');
 ref:=nullif(upper(trim(new.raw_user_meta_data->>'referral_code')),'');
 if not operator and not pending then
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
 if operator then update private.operator_setup set user_id=new.id where email=lower(new.email); end if;
 return new;
end $$;

create function public.complete_referral_join(p_full_name text,p_phone text,p_referral_code text,p_consent boolean)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); sponsor uuid; state public.account_status;
begin
 if uid is null then raise exception 'Sign in first'; end if;
 select status into state from public.member_profiles where user_id=uid for update;
 if state is distinct from 'pending' then raise exception 'Pending onboarding required'; end if;
 if length(trim(coalesce(p_full_name,'')))<2 or length(trim(coalesce(p_phone,'')))<5 or p_consent is distinct from true then raise exception 'Complete your name, phone and consent'; end if;
 select user_id into sponsor from public.member_profiles where (upper(referral_code)=upper(trim(p_referral_code)) or upper(member_code)=upper(trim(p_referral_code))) and status='active';
 if sponsor is null or sponsor=uid then raise exception 'Valid referral code is required'; end if;
 update public.member_profiles set full_name=trim(p_full_name),phone=trim(p_phone),sponsor_id=sponsor,status='active',terms_accepted_at=now(),terms_version='phase1-terms-v1',updated_at=now() where user_id=uid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(uid,'REFERRAL_JOIN_COMPLETED','member',uid,jsonb_build_object('sponsor_id',sponsor));
end $$;
revoke all on function public.complete_referral_join(text,text,text,boolean) from public,anon;
grant execute on function public.complete_referral_join(text,text,text,boolean) to authenticated;

create function public.finish_operator_setup(p_user_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from private.operator_setup s join auth.users u on u.id=s.user_id and lower(u.email)=s.email where s.user_id=p_user_id and s.expires_at>now()) then raise exception 'Setup is unavailable'; end if;
 insert into public.user_roles(user_id,role) values(p_user_id,'admin') on conflict do nothing;
 insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,is_company_owned)
 values(p_user_id,'Market is Online','m.shujaat1993@gmail.com',null,'Market is Online company store','active',true) on conflict(owner_user_id) do nothing;
 update private.operator_setup set expires_at=now() where user_id=p_user_id;
end $$;
revoke all on function public.finish_operator_setup(uuid) from public,anon,authenticated;
grant execute on function public.finish_operator_setup(uuid) to service_role;

create function private.require_recent_totp()
returns void language plpgsql security definer set search_path='' as $$
declare claims jsonb:=coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb;
begin
 if claims->>'aal' is distinct from 'aal2' or not exists(select 1 from jsonb_array_elements(coalesce(claims->'amr','[]')) a where a->>'method'='totp' and (a->>'timestamp')::numeric between extract(epoch from now())-120 and extract(epoch from now())+5) then raise exception 'Verify a current authenticator code before this action'; end if;
end $$;
revoke all on function private.require_recent_totp() from public,anon,authenticated;
alter function public.admin_mint_own_mio(numeric,text,text) set schema private;
alter function public.admin_burn_own_mio(numeric,text,text) set schema private;
alter function public.mio_transfer(uuid,numeric,text) set schema private;
revoke all on function private.admin_mint_own_mio(numeric,text,text),private.admin_burn_own_mio(numeric,text,text),private.mio_transfer(uuid,numeric,text) from public,anon,authenticated;
create function public.admin_mint_own_mio(p_amount numeric,p_reason text,p_idempotency_key text) returns numeric language plpgsql security definer set search_path='' as $$begin perform private.require_recent_totp(); return private.admin_mint_own_mio(p_amount,p_reason,p_idempotency_key); end $$;
create function public.admin_burn_own_mio(p_amount numeric,p_reason text,p_idempotency_key text) returns numeric language plpgsql security definer set search_path='' as $$begin perform private.require_recent_totp(); return private.admin_burn_own_mio(p_amount,p_reason,p_idempotency_key); end $$;
create function public.mio_transfer(p_recipient_id uuid,p_amount numeric,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$begin if private.has_role('admin') then perform private.require_recent_totp(); end if; return private.mio_transfer(p_recipient_id,p_amount,p_idempotency_key); end $$;
revoke all on function public.admin_mint_own_mio(numeric,text,text),public.admin_burn_own_mio(numeric,text,text),public.mio_transfer(uuid,numeric,text) from public,anon;
grant execute on function public.admin_mint_own_mio(numeric,text,text),public.admin_burn_own_mio(numeric,text,text),public.mio_transfer(uuid,numeric,text) to authenticated;

create table public.support_tickets(id uuid primary key default gen_random_uuid(),email text not null,message text not null,tracking_hash text not null,status text not null default 'open' check(status in('open','answered','closed')),response text,created_at timestamptz not null default now(),answered_at timestamptz,answered_by uuid references auth.users(id));
alter table public.support_tickets enable row level security;
create policy "operations reads tickets" on public.support_tickets for select to authenticated using(private.has_role('admin'));
grant select on public.support_tickets to authenticated;
revoke insert,update,delete on public.support_tickets from anon,authenticated;
create index support_tickets_email_time_idx on public.support_tickets(email,created_at);
create function public.request_recovery_ticket(p_email text,p_message text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare mail text:=lower(trim(p_email)); token text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''); tid uuid;
begin
 if mail is null or length(mail)>254 or mail !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(trim(coalesce(p_message,'')))<10 or length(p_message)>2000 then raise exception 'Enter a valid email and a message of 10–2000 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended('ticket:'||mail,0));
 if (select count(*) from public.support_tickets where email=mail and created_at>now()-interval '1 hour')>=3 then raise exception 'Please wait before submitting another ticket'; end if;
 insert into public.support_tickets(email,message,tracking_hash) values(mail,trim(p_message),encode(sha256(convert_to(token,'UTF8')),'hex')) returning id into tid;
 return jsonb_build_object('ticket_id',tid,'tracking_key',token);
end $$;
create function public.track_recovery_ticket(p_ticket_id uuid,p_tracking_key text)
returns table(status text,response text,created_at timestamptz,answered_at timestamptz) language sql stable security definer set search_path='' as $$
 select t.status,t.response,t.created_at,t.answered_at from public.support_tickets t where t.id=p_ticket_id and t.tracking_hash=encode(sha256(convert_to(p_tracking_key,'UTF8')),'hex');
$$;
create function public.answer_recovery_ticket(p_ticket_id uuid,p_response text,p_close boolean)
returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if length(trim(coalesce(p_response,'')))<10 or length(p_response)>4000 then raise exception 'Response must contain 10–4000 characters'; end if;
 update public.support_tickets set response=trim(p_response),status=case when p_close then 'closed' else 'answered' end,answered_at=now(),answered_by=auth.uid() where id=p_ticket_id;
 if not found then raise exception 'Ticket not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'RECOVERY_TICKET_ANSWERED','support_ticket',p_ticket_id);
end $$;
revoke all on function public.request_recovery_ticket(text,text),public.track_recovery_ticket(uuid,text),public.answer_recovery_ticket(uuid,text,boolean) from public;
grant execute on function public.request_recovery_ticket(text,text),public.track_recovery_ticket(uuid,text) to anon,authenticated;
grant execute on function public.answer_recovery_ticket(uuid,text,boolean) to authenticated;
