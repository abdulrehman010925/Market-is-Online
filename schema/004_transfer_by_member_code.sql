create function public.mio_transfer_to_member_code(p_recipient_code text, p_amount numeric, p_idempotency_key text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  select user_id into recipient from public.member_profiles
    where upper(member_code)=upper(trim(p_recipient_code)) or upper(referral_code)=upper(trim(p_recipient_code))
    limit 1;
  if recipient is null then raise exception 'Member code not found'; end if;
  return public.mio_transfer(recipient,p_amount,p_idempotency_key);
end;
$$;
revoke all on function public.mio_transfer_to_member_code(text,numeric,text) from public, anon;
grant execute on function public.mio_transfer_to_member_code(text,numeric,text) to authenticated;
