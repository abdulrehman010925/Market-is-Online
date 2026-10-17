-- Confirmed Phase 1 MIO currency rules. All balances are ledger-backed.
-- This migration adds no sample members, products, balances, or transactions.

alter table public.vendors
  add column if not exists is_company_owned boolean not null default false;

alter table public.package_activations
  drop constraint if exists package_activations_source_check;
alter table public.package_activations
  add constraint package_activations_source_check
  check (source in ('SUBSCRIPTION','SHOPPING_PPV','MIO_POINTS','ADMIN'));

create table public.mio_wallet_accounts (
  member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
  balance numeric(20,4) not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table public.mio_ledger (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.member_profiles(user_id),
  amount numeric(20,4) not null check (amount <> 0),
  action text not null check (action in ('admin_mint','admin_burn','transfer_in','transfer_out','package_activation')),
  counterparty_id uuid references public.member_profiles(user_id),
  transfer_id uuid,
  activation_id uuid references public.package_activations(id),
  reason text,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  check ((action in ('transfer_in','transfer_out') and counterparty_id is not null and transfer_id is not null)
    or (action not in ('transfer_in','transfer_out') and counterparty_id is null and transfer_id is null)),
  check ((action = 'package_activation' and activation_id is not null)
    or (action <> 'package_activation' and activation_id is null)),
  check ((action in ('admin_mint','transfer_in') and amount > 0)
    or (action in ('admin_burn','transfer_out','package_activation') and amount < 0))
);
create index mio_ledger_member_time_idx on public.mio_ledger(member_id, created_at desc);
create index mio_ledger_transfer_idx on public.mio_ledger(transfer_id) where transfer_id is not null;

alter table public.mio_wallet_accounts enable row level security;
alter table public.mio_ledger enable row level security;
create policy "members read own MIO wallet" on public.mio_wallet_accounts
  for select to authenticated using (member_id = (select auth.uid()) or private.has_role('admin'));
create policy "members read own MIO ledger" on public.mio_ledger
  for select to authenticated using (member_id = (select auth.uid()) or private.has_role('admin'));
grant select on public.mio_wallet_accounts, public.mio_ledger to authenticated;
revoke insert, update, delete on public.mio_wallet_accounts, public.mio_ledger from anon, authenticated;

create function private.ensure_mio_wallet()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.mio_wallet_accounts(member_id) values (new.user_id)
  on conflict (member_id) do nothing;
  return new;
end;
$$;
revoke all on function private.ensure_mio_wallet() from public, anon, authenticated;
create trigger create_member_mio_wallet after insert on public.member_profiles
  for each row execute function private.ensure_mio_wallet();
insert into public.mio_wallet_accounts(member_id)
select user_id from public.member_profiles on conflict (member_id) do nothing;

create function private.current_package_code(p_member_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select a.package_code
  from public.package_activations a
  where a.member_id = p_member_id and a.status = 'approved'
  order by a.activated_at desc nulls last, a.requested_at desc
  limit 1;
$$;
revoke all on function private.current_package_code(uuid) from public, anon, authenticated;
grant execute on function private.current_package_code(uuid) to authenticated;

create function public.mio_transfer(p_recipient_id uuid, p_amount numeric, p_idempotency_key text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  sender_id uuid := (select auth.uid());
  transfer_key uuid := gen_random_uuid();
  sender_admin boolean;
  recipient_admin boolean;
  sender_premium boolean;
  recipient_premium boolean;
  existing_transfer uuid;
  locked_user uuid;
  wallet_balance numeric(20,4);
begin
  if sender_id is null then raise exception 'Authentication required'; end if;
  if p_recipient_id is null or p_recipient_id = sender_id then raise exception 'Choose another member'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then raise exception 'Invalid MIO amount'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 or length(p_idempotency_key) > 100 then raise exception 'Invalid idempotency key'; end if;

  select transfer_id into existing_transfer from public.mio_ledger
    where idempotency_key = p_idempotency_key || ':out';
  if existing_transfer is not null then return existing_transfer; end if;

  select private.has_role('admin') into sender_admin;
  select exists(select 1 from public.user_roles r where r.user_id=p_recipient_id and r.role='admin')
    into recipient_admin;
  sender_premium := private.current_package_code(sender_id) = 'PREMIUM';
  recipient_premium := private.current_package_code(p_recipient_id) = 'PREMIUM';
  if sender_admin or recipient_admin then
    if not ((sender_admin and recipient_premium) or (recipient_admin and sender_premium)) then
      raise exception 'Admin MIO transfers are allowed only with Premium members';
    end if;
  elsif not (sender_premium or recipient_premium) then
    raise exception 'At least one member in a MIO transfer must hold the Premium package';
  end if;

  -- Lock in a deterministic order to prevent double-spending and deadlocks.
  for locked_user in
    select member_id from public.mio_wallet_accounts
    where member_id in (sender_id, p_recipient_id) order by member_id
    for update
  loop null; end loop;
  select balance into wallet_balance from public.mio_wallet_accounts where member_id = sender_id;
  if wallet_balance < p_amount then raise exception 'Insufficient MIO balance'; end if;

  update public.mio_wallet_accounts set balance = balance - p_amount, updated_at = now() where member_id = sender_id;
  update public.mio_wallet_accounts set balance = balance + p_amount, updated_at = now() where member_id = p_recipient_id;
  insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,idempotency_key)
    values (sender_id,-p_amount,'transfer_out',p_recipient_id,transfer_key,p_idempotency_key || ':out'),
           (p_recipient_id,p_amount,'transfer_in',sender_id,transfer_key,p_idempotency_key || ':in');
  return transfer_key;
end;
$$;
revoke all on function public.mio_transfer(uuid,numeric,text) from public, anon;
grant execute on function public.mio_transfer(uuid,numeric,text) to authenticated;

create function public.admin_mint_own_mio(p_amount numeric, p_reason text, p_idempotency_key text)
returns numeric language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid()); new_balance numeric(20,4);
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then raise exception 'Invalid MIO amount'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason is required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  update public.mio_wallet_accounts set balance = balance + p_amount, updated_at = now()
    where member_id = admin_id returning balance into new_balance;
  if new_balance is null then raise exception 'Admin wallet is not initialized'; end if;
  insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key)
    values (admin_id,p_amount,'admin_mint',trim(p_reason),p_idempotency_key);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ADMIN_MIO_MINT','mio_wallet',admin_id,jsonb_build_object('amount',p_amount,'reason',trim(p_reason),'balance',new_balance));
  return new_balance;
end;
$$;
revoke all on function public.admin_mint_own_mio(numeric,text,text) from public, anon;
grant execute on function public.admin_mint_own_mio(numeric,text,text) to authenticated;

create function public.admin_burn_own_mio(p_amount numeric, p_reason text, p_idempotency_key text)
returns numeric language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid()); new_balance numeric(20,4);
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid MIO amount'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason is required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  update public.mio_wallet_accounts set balance = balance - p_amount, updated_at = now()
    where member_id = admin_id and balance >= p_amount returning balance into new_balance;
  if new_balance is null then raise exception 'Insufficient admin MIO balance'; end if;
  insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key)
    values (admin_id,-p_amount,'admin_burn',trim(p_reason),p_idempotency_key);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ADMIN_MIO_BURN','mio_wallet',admin_id,jsonb_build_object('amount',p_amount,'reason',trim(p_reason),'balance',new_balance));
  return new_balance;
end;
$$;
revoke all on function public.admin_burn_own_mio(numeric,text,text) from public, anon;
grant execute on function public.admin_burn_own_mio(numeric,text,text) to authenticated;

create function public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  member uuid := (select auth.uid());
  p public.package_versions%rowtype;
  current_code text;
  current_price numeric(14,2);
  activation uuid := gen_random_uuid();
  new_balance numeric(20,4);
begin
  if member is null then raise exception 'Authentication required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  if not exists(select 1 from public.member_profiles where user_id=member and status='active') then
    raise exception 'Active member account required';
  end if;
  select * into p from public.package_versions where package_code=p_package_code and is_active
    and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
  if p.package_code is null then raise exception 'Package not available'; end if;
  current_code := private.current_package_code(member);
  if current_code is not null then
    select payable_price into current_price from public.package_versions where package_code=current_code order by version desc limit 1;
    if p.payable_price <= coalesce(current_price,0) then raise exception 'Choose a higher package tier'; end if;
  end if;
  update public.mio_wallet_accounts set balance=balance-p.payable_price, updated_at=now()
    where member_id=member and balance >= p.payable_price returning balance into new_balance;
  if new_balance is null then raise exception 'Insufficient MIO Points'; end if;
  insert into public.package_activations(
    id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,
    base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,
    status,activated_at,approved_by,idempotency_key)
  values(activation,member,p.package_code,p.version,'MIO_POINTS',p_idempotency_key,'MIO',p.payable_price,1,
    p.base_value,p.company_fee,p.payable_price,p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
    'approved',now(),member,p_idempotency_key);
  insert into public.mio_ledger(member_id,amount,action,activation_id,idempotency_key)
    values(member,-p.payable_price,'package_activation',activation,p_idempotency_key || ':mio');
  insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
    values(member,'PPV',p.ppv,activation,'credit',p_idempotency_key || ':ppv');
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,jsonb_build_object('package_code',p.package_code,'payable_mio',p.payable_price,'ppv_credited',p.ppv));
  return activation;
end;
$$;
revoke all on function public.activate_package_with_mio(text,text) from public, anon;
grant execute on function public.activate_package_with_mio(text,text) to authenticated;

create table public.featured_products (
  position smallint primary key check(position between 1 and 6),
  product_id uuid not null unique references public.products(id) on delete cascade,
  selected_by uuid not null references auth.users(id),
  selected_at timestamptz not null default now()
);
alter table public.featured_products enable row level security;
create policy "featured approved products are public" on public.featured_products
  for select to anon,authenticated using (
    exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
      where p.id=product_id and p.status='approved' and v.status='active' and v.is_company_owned)
  );
grant select on public.featured_products to anon, authenticated;
revoke insert, update, delete on public.featured_products from anon, authenticated;

create function public.set_featured_products(p_product_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid()); n integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if coalesce(array_length(p_product_ids,1),0) > 6 then raise exception 'Select at most six featured products'; end if;
  if (select count(distinct x) from unnest(coalesce(p_product_ids,'{}'::uuid[])) x) <> coalesce(array_length(p_product_ids,1),0) then
    raise exception 'Duplicate featured product';
  end if;
  if exists(select 1 from unnest(coalesce(p_product_ids,'{}'::uuid[])) x
    where not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
      where p.id=x and p.status='approved' and v.status='active' and v.is_company_owned)) then
    raise exception 'Featured selections must be approved products owned by Market is Online';
  end if;
  delete from public.featured_products;
  insert into public.featured_products(position,product_id,selected_by)
    select ordinality::smallint, product_id, admin_id from unnest(coalesce(p_product_ids,'{}'::uuid[])) with ordinality u(product_id,ordinality);
  n := coalesce(array_length(p_product_ids,1),0);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'FEATURED_PRODUCTS_SET','featured_products',jsonb_build_object('count',n,'product_ids',p_product_ids));
  return n;
end;
$$;
revoke all on function public.set_featured_products(uuid[]) from public, anon;
grant execute on function public.set_featured_products(uuid[]) to authenticated;

-- No top-up/payment provider is connected in this phase yet. MIO balances
-- cannot be increased through browser writes; use audited admin-own-wallet RPC
-- or add a verified settlement provider before enabling member purchases.
