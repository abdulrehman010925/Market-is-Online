-- Restore the guest affiliate approval objects that precede the October 29
-- guarantee upgrade. The live database already has these objects; this file
-- makes a fresh migration replay and the local simulation self-contained.
create table if not exists public.affiliate_guest_order_approvals (
  order_id uuid primary key references public.orders(id) on delete cascade,
  sponsor_id uuid not null references public.member_profiles(user_id),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','released','cancelled_refunded')),
  hold_mio numeric(20,4) not null default 2 check (hold_mio=2),
  approved_at timestamptz,
  released_at timestamptz,
  rejected_at timestamptz,
  approval_request_key text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.affiliate_guest_order_approvals enable row level security;
revoke all on table public.affiliate_guest_order_approvals from public, anon, authenticated;

alter table public.mio_ledger drop constraint if exists mio_ledger_action_check;
alter table public.mio_ledger add constraint mio_ledger_action_check check (action in (
  'admin_mint','admin_burn','transfer_in','transfer_out','package_activation',
  'bonus_credit','purchase_in','purchase_out','proceed_conversion',
  'withdrawal_fee','affiliate_order_hold','affiliate_order_refund'
));
alter table public.mio_ledger drop constraint if exists mio_ledger_activation_source_check;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check check (
  (action in ('package_activation','bonus_credit') and
    num_nonnulls(activation_id,cycle_id,source_order_id)=1) or
  (action in ('affiliate_order_hold','affiliate_order_refund') and
    source_order_id is not null and activation_id is null and cycle_id is null) or
  (action not in ('package_activation','bonus_credit','affiliate_order_hold','affiliate_order_refund') and
    num_nonnulls(activation_id,cycle_id,source_order_id)=0)
);
alter table public.mio_ledger drop constraint if exists mio_ledger_amount_check;
alter table public.mio_ledger add constraint mio_ledger_amount_check check (
  (action in ('admin_mint','transfer_in','bonus_credit','purchase_in','proceed_conversion','withdrawal_fee','affiliate_order_refund') and amount>0) or
  (action in ('admin_burn','transfer_out','package_activation','purchase_out','affiliate_order_hold') and amount<0)
);

create or replace function private.create_affiliate_guest_approval(p_order uuid)
returns void language plpgsql security definer set search_path='' as $function$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where id=p_order;
  if o.id is null or o.buyer_id is not null or o.selling_affiliate_id is null then return; end if;
  insert into public.affiliate_guest_order_approvals(order_id,sponsor_id)
  values(o.id,o.selling_affiliate_id) on conflict(order_id) do nothing;
end
$function$;

create or replace function private.create_affiliate_guest_approval_trigger()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  perform private.create_affiliate_guest_approval(new.id);
  return new;
end
$function$;
create trigger create_affiliate_guest_approval after insert on public.orders
for each row execute function private.create_affiliate_guest_approval_trigger();

create or replace function private.enforce_affiliate_guest_approval()
returns trigger language plpgsql security definer set search_path='' as $function$
declare approval text;
begin
  if old.buyer_id is not null or old.selling_affiliate_id is null then return new; end if;
  select status into approval from public.affiliate_guest_order_approvals where order_id=old.id;
  if coalesce(approval,'pending') not in ('approved','released') and (
    (new.payment_status='confirmed' and old.payment_status<>'confirmed') or
    (new.status in ('confirmed','processing','shipped','delivered') and new.status<>old.status)
  ) then raise exception 'Selling member approval is required before processing this guest order'; end if;
  return new;
end
$function$;
create trigger aa_enforce_affiliate_guest_approval
before update of status, payment_status on public.orders
for each row execute function private.enforce_affiliate_guest_approval();

revoke all on function private.create_affiliate_guest_approval(uuid),
  private.create_affiliate_guest_approval_trigger(),
  private.enforce_affiliate_guest_approval() from public, anon, authenticated;
