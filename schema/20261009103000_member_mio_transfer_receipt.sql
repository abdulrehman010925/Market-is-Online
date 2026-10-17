-- Allow only a participant in a recorded transfer to see both sides of its receipt.
create or replace function public.lookup_mio_transfer_receipt(p_transfer_id uuid)
returns table(
  transfer_id uuid,
  created_at timestamptz,
  amount numeric(20,4),
  sender_id uuid,
  sender_name text,
  sender_code text,
  recipient_id uuid,
  recipient_name text,
  recipient_code text,
  reason text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in required';
  end if;

  if not exists (
    select 1 from public.mio_ledger l
    where l.transfer_id = p_transfer_id
      and l.member_id = auth.uid()
      and l.action in ('transfer_in','transfer_out')
  ) then
    raise exception 'Transfer not found for this account';
  end if;

  return query
  select out_row.transfer_id,
         out_row.created_at,
         abs(out_row.amount)::numeric(20,4),
         sender.user_id,
         sender.full_name,
         sender.member_code,
         recipient.user_id,
         recipient.full_name,
         recipient.member_code,
         coalesce(out_row.reason, in_row.reason)
  from public.mio_ledger out_row
  join public.mio_ledger in_row
    on in_row.transfer_id = out_row.transfer_id
   and in_row.action = 'transfer_in'
  join public.member_profiles sender on sender.user_id = out_row.member_id
  join public.member_profiles recipient on recipient.user_id = in_row.member_id
  where out_row.transfer_id = p_transfer_id
    and out_row.action = 'transfer_out';
end;
$$;
revoke all on function public.lookup_mio_transfer_receipt(uuid) from public, anon;
grant execute on function public.lookup_mio_transfer_receipt(uuid) to authenticated;
