create or replace function private.require_transaction_pin(p_pin text,p_member_id uuid default auth.uid())
returns void language plpgsql security definer set search_path to '' as $function$
declare stored text;
begin
 if p_member_id is null then raise exception 'Authentication required'; end if;
 if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then raise exception 'Enter your 4 to 6 digit transaction PIN'; end if;
 select transaction_pin_hash into stored from public.member_profiles where user_id=p_member_id;
 if stored is null then raise exception 'Set your transaction PIN in Account security first'; end if;
 if extensions.crypt(p_pin,stored) <> stored then raise exception 'Invalid transaction PIN'; end if;
end $function$;

create or replace function public.set_transaction_pin(p_pin text)
returns void language plpgsql security definer set search_path to '' as $function$
declare uid uuid:=auth.uid(); existing_hash text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then raise exception 'Transaction PIN must contain 4 to 6 digits'; end if;
 select transaction_pin_hash into existing_hash from public.member_profiles where user_id=uid for update;
 if not found then raise exception 'Member account required'; end if;
 if existing_hash is not null then raise exception 'Transaction PIN already exists. Verify your previous PIN or authenticator code to change it.'; end if;
 update public.member_profiles set transaction_pin_hash=extensions.crypt(p_pin,extensions.gen_salt('bf')),transaction_pin_set_at=now(),transaction_pin_updated_at=now(),updated_at=now() where user_id=uid;
end $function$;

create or replace function public.change_transaction_pin(p_new_pin text,p_current_pin text default null)
returns void language plpgsql security definer set search_path to '' as $function$
declare uid uuid:=auth.uid(); existing_hash text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_new_pin is null or p_new_pin !~ '^[0-9]{4,6}$' then raise exception 'New transaction PIN must contain 4 to 6 digits'; end if;
 select transaction_pin_hash into existing_hash from public.member_profiles where user_id=uid for update;
 if not found then raise exception 'Member account required'; end if;
 if existing_hash is null then raise exception 'No transaction PIN exists. Set your PIN first.'; end if;
 if nullif(trim(coalesce(p_current_pin,'')),'') is not null then perform private.require_transaction_pin(p_current_pin,uid); else perform private.require_recent_totp(); end if;
 update public.member_profiles set transaction_pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf')),transaction_pin_updated_at=now(),updated_at=now() where user_id=uid;
end $function$;

revoke all on function public.set_transaction_pin(text) from public,anon;
grant execute on function public.set_transaction_pin(text) to authenticated;
revoke all on function public.change_transaction_pin(text,text) from public,anon;
grant execute on function public.change_transaction_pin(text,text) to authenticated;
