-- Market is Online complete database schema setup
-- Ordered schema and latest Supabase migrations. Run on a fresh project.
-- Auth passwords, private keys and live user data are intentionally excluded.

-- ===== schema/001_phase1_postgres.sql =====
-- Market is Online, Phase 1 PostgreSQL/Supabase schema.
-- No member, vendor, product, order, activation, or earnings demo rows are seeded.
-- The package rows below are confirmed business configuration, not sample activity.
-- Apply only after the owner chooses a database project and the remaining launch rules.

create schema if not exists private;

create type public.app_role as enum ('member','vendor','admin');
create type public.account_status as enum ('pending','active','suspended','closed');
create type public.vendor_status as enum ('pending','active','rejected','suspended');
create type public.product_status as enum ('draft','pending','approved','rejected','archived');
create type public.order_status as enum ('placed','confirmed','processing','shipped','delivered','cancelled','returned');
create type public.payment_status as enum ('unconfirmed','confirmed','failed','refunded');
create type public.activation_status as enum ('pending','approved','rejected','reversed');
create type public.ledger_entry_kind as enum ('credit','debit','reversal','adjustment');
create type public.bonus_method as enum ('direct','generation','binary_pool_share');

create table public.member_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  member_code text not null unique,
  referral_code text not null unique,
  full_name text not null,
  phone text,
  country_code char(2) not null default 'PK',
  sponsor_id uuid references public.member_profiles(user_id),
  status public.account_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (sponsor_id is null or sponsor_id <> user_id)
);
create index member_profiles_sponsor_idx on public.member_profiles(sponsor_id);

create table public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create function private.has_role(_role public.app_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = _role
  );
$$;
revoke all on function private.has_role(public.app_role) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.has_role(public.app_role) to authenticated;

create function private.create_member_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  sponsor uuid;
  display_name text;
  ref_code text;
begin
  display_name := nullif(trim(new.raw_user_meta_data ->> 'full_name'), '');
  if display_name is null then display_name := 'Member'; end if;
  select user_id into sponsor from public.member_profiles
    where referral_code = nullif(trim(new.raw_user_meta_data ->> 'referral_code'), '')
      and status = 'active' limit 1;
  ref_code := upper(substr(replace(new.id::text, '-', ''), 1, 10));
  insert into public.member_profiles(user_id, member_code, referral_code, full_name, phone, country_code, sponsor_id)
    values (new.id, 'MIO-' || ref_code, ref_code, display_name,
      nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
      coalesce(nullif(upper(trim(new.raw_user_meta_data ->> 'country_code')), ''), 'PK'), sponsor);
  insert into public.user_roles(user_id, role) values (new.id, 'member');
  return new;
end;
$$;
revoke all on function private.create_member_profile() from public, anon, authenticated;
create trigger on_auth_user_created
after insert on auth.users for each row execute function private.create_member_profile();

create table public.package_versions (
  package_code text not null,
  version integer not null,
  display_name text not null,
  base_value numeric(14,2) not null check (base_value > 0),
  company_fee numeric(14,2) not null check (company_fee >= 0),
  payable_price numeric(14,2) generated always as (base_value + company_fee) stored,
  ppv numeric(14,4) not null,
  bv numeric(14,4) not null,
  dp numeric(14,4) not null,
  gp numeric(14,4) not null,
  bp numeric(14,4) not null,
  brp numeric(14,4) not null,
  max_generations smallint not null check (max_generations between 1 and 10),
  direct_rate numeric(8,6) not null check (direct_rate between 0 and 1),
  generation1_rate numeric(8,6) not null check (generation1_rate between 0 and 1),
  binary_entitlement numeric(8,6) not null check (binary_entitlement between 0 and 1),
  currency char(3) not null default 'USD',
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key(package_code, version),
  check(effective_to is null or effective_to > effective_from)
);

create table public.system_config (
  config_key text not null,
  version integer not null,
  config_value jsonb not null,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key(config_key, version),
  check(effective_to is null or effective_to > effective_from)
);

-- Vendors are multi-vendor marketplace accounts. No vendor fees or commission
-- are assumed; seller terms and settlement remain disabled pending owner rules.
create table public.vendor_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_user_id uuid not null references auth.users(id),
  business_name text not null,
  contact_email text not null,
  contact_phone text not null,
  categories text not null,
  description text,
  status public.vendor_status not null default 'pending',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(applicant_user_id)
);

create table public.vendors (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  business_name text not null,
  contact_email text not null,
  contact_phone text not null,
  description text,
  status public.vendor_status not null default 'pending',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(owner_user_id)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references public.vendors(id),
  sku text,
  name text not null,
  description text not null default '',
  category text,
  image_url text,
  price_pkr numeric(14,2) not null check (price_pkr >= 0),
  stock_quantity integer not null default 0 check (stock_quantity >= 0),
  status public.product_status not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(vendor_id, sku)
);
create index products_marketplace_idx on public.products(category, created_at desc) where status = 'approved';

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,
  buyer_id uuid not null references auth.users(id),
  currency char(3) not null default 'PKR' check (currency = 'PKR'),
  subtotal_pkr numeric(14,2) not null check (subtotal_pkr >= 0),
  delivery_fee_pkr numeric(14,2) not null default 0 check (delivery_fee_pkr >= 0),
  total_pkr numeric(14,2) not null check (total_pkr = subtotal_pkr + delivery_fee_pkr),
  payment_method text not null default 'COD' check (payment_method in ('COD','MANUAL')),
  payment_status public.payment_status not null default 'unconfirmed',
  status public.order_status not null default 'placed',
  shipping_name text not null,
  shipping_phone text not null,
  shipping_address text not null,
  shipping_city text not null,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index orders_buyer_time_idx on public.orders(buyer_id, created_at desc);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  product_id uuid not null references public.products(id),
  vendor_id uuid not null references public.vendors(id),
  product_name_snapshot text not null,
  unit_price_pkr numeric(14,2) not null check (unit_price_pkr >= 0),
  quantity integer not null check (quantity > 0),
  line_total_pkr numeric(14,2) generated always as (unit_price_pkr * quantity) stored,
  fulfillment_status text not null default 'placed'
    check (fulfillment_status in ('placed','confirmed','processing','shipped','delivered','cancelled','returned')),
  created_at timestamptz not null default now()
);
create index order_items_vendor_idx on public.order_items(vendor_id, fulfillment_status);

create table public.binary_placements (
  member_id uuid primary key references public.member_profiles(user_id),
  parent_id uuid references public.member_profiles(user_id),
  side text check (side in ('LEFT','RIGHT')),
  placed_by uuid references auth.users(id),
  placed_at timestamptz not null default now(),
  check(member_id <> parent_id),
  check((parent_id is null and side is null) or (parent_id is not null and side is not null)),
  unique(parent_id, side)
);
create index binary_placements_parent_idx on public.binary_placements(parent_id);

create table public.package_activations (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.member_profiles(user_id),
  package_code text not null,
  package_version integer not null,
  source text not null check(source in ('SUBSCRIPTION','SHOPPING_PPV','ADMIN')),
  source_reference text,
  -- Package plan is USD-denominated. PKR conversion rate must be configured and
  -- snapshotted before a PKR payment request can be created.
  payment_currency char(3),
  payment_amount numeric(14,2),
  usd_to_payment_rate numeric(14,6),
  base_value numeric(14,2) not null,
  company_fee numeric(14,2) not null,
  payable_price numeric(14,2) not null,
  ppv numeric(14,4) not null,
  bv numeric(14,4) not null,
  dp numeric(14,4) not null,
  gp numeric(14,4) not null,
  bp numeric(14,4) not null,
  brp numeric(14,4) not null,
  direct_rate numeric(8,6) not null,
  generation1_rate numeric(8,6) not null,
  binary_entitlement numeric(8,6) not null,
  status public.activation_status not null default 'pending',
  requested_at timestamptz not null default now(),
  activated_at timestamptz,
  approved_by uuid references auth.users(id),
  idempotency_key text not null unique,
  foreign key(package_code, package_version) references public.package_versions(package_code,version),
  check(payable_price = base_value + company_fee),
  check((payment_currency is null and payment_amount is null and usd_to_payment_rate is null)
    or (payment_currency is not null and payment_amount is not null and usd_to_payment_rate is not null and usd_to_payment_rate > 0))
);
create index package_activations_member_time_idx on public.package_activations(member_id, requested_at desc);

create table public.point_ledger (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.member_profiles(user_id),
  point_type text not null check(point_type in ('PPV','BV','DP','GP','BP','BRP')),
  amount numeric(18,4) not null check(amount <> 0),
  side text check(side in ('LEFT','RIGHT')),
  source_activation_id uuid references public.package_activations(id),
  source_order_id uuid references public.orders(id),
  entry_kind public.ledger_entry_kind not null,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  check((point_type = 'BP' and side is not null) or (point_type <> 'BP' and side is null)),
  check(num_nonnulls(source_activation_id,source_order_id)=1),
  unique(member_id,point_type,source_activation_id,entry_kind),
  unique(member_id,point_type,source_order_id,entry_kind)
);
create index point_ledger_member_idx on public.point_ledger(member_id,point_type,created_at desc);

create table public.binary_cycles (
  id uuid primary key default gen_random_uuid(),
  cycle_code text not null unique,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  cycle_timezone text,
  eligible_base numeric(18,4) not null default 0,
  pool_rate numeric(8,6) not null default 0.35 check(pool_rate = 0.35),
  pool_amount numeric(18,8) not null default 0,
  total_completed_shares bigint not null default 0,
  gross_share_value numeric(18,10),
  status text not null default 'open' check(status in ('open','frozen','posted','unallocated','reversed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  check(ends_at > starts_at)
);

create table public.binary_member_results (
  cycle_id uuid not null references public.binary_cycles(id),
  member_id uuid not null references public.member_profiles(user_id),
  package_code text not null,
  package_version integer not null,
  left_available numeric(18,4) not null,
  right_available numeric(18,4) not null,
  completed_shares bigint not null check(completed_shares >= 0),
  entitlement numeric(8,6) not null,
  gross_amount numeric(18,8) not null,
  member_amount numeric(18,8) not null,
  company_retention numeric(18,8) not null,
  consumed_left numeric(18,4) not null,
  consumed_right numeric(18,4) not null,
  carry_left numeric(18,4) not null,
  carry_right numeric(18,4) not null,
  qualification_snapshot jsonb not null,
  primary key(cycle_id,member_id),
  foreign key(package_code,package_version) references public.package_versions(package_code,version),
  check(member_amount + company_retention = gross_amount),
  check(consumed_left = completed_shares * 50 and consumed_right = completed_shares * 50)
);

create table public.bonus_transactions (
  id uuid primary key default gen_random_uuid(),
  beneficiary_id uuid not null references public.member_profiles(user_id),
  method public.bonus_method not null,
  source_activation_id uuid references public.package_activations(id),
  cycle_id uuid references public.binary_cycles(id),
  generation smallint,
  qualifying_base numeric(18,8) not null,
  rate numeric(10,8),
  gross_amount numeric(18,8) not null,
  payable_amount numeric(18,8) not null,
  currency char(3) not null default 'USD',
  formula_version text not null,
  calculation_trace jsonb not null,
  status text not null default 'posted' check(status in ('pending','posted','reversed')),
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  check((method = 'binary_pool_share' and cycle_id is not null and source_activation_id is null)
    or (method <> 'binary_pool_share' and source_activation_id is not null and cycle_id is null))
);
create index bonus_beneficiary_idx on public.bonus_transactions(beneficiary_id,created_at desc);

create table public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.member_profiles(user_id),
  entry_type public.ledger_entry_kind not null,
  amount numeric(18,8) not null check(amount <> 0),
  currency char(3) not null default 'USD',
  bonus_transaction_id uuid references public.bonus_transactions(id),
  source_reference text not null,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);
create index wallet_member_idx on public.wallet_ledger(member_id,created_at desc);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

-- Confirmed plan configuration. No fake members, vendors, products, or transactions.
insert into public.package_versions
(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement,effective_from)
values
('BASIC_1',1,'Basic 1',10,1,11,10,10,5,5,5,2,.20,.20,.50,'2026-01-01T00:00:00Z'),
('BASIC_2',1,'Basic 2',20,2,22,20,20,10,10,10,4,.22,.22,.60,'2026-01-01T00:00:00Z'),
('ADVANCED_1',1,'Advanced 1',50,5,55,50,50,25,25,25,6,.24,.24,.70,'2026-01-01T00:00:00Z'),
('ADVANCED_2',1,'Advanced 2',100,10,110,100,100,50,50,50,8,.26,.26,.80,'2026-01-01T00:00:00Z'),
('PREMIUM',1,'Premium',500,50,550,500,500,250,250,250,10,.30,.30,1.00,'2026-01-01T00:00:00Z');

insert into public.system_config(config_key,version,config_value,effective_from)
values
('BINARY_POOL_SHARE',1,'{"pool_rate":0.35,"points_per_side_per_share":50,"carry_forward":true,"zero_share_policy":"UNALLOCATED_PENDING_OWNER_RULE","qualification":"PENDING_OWNER_RULE","cycle_timezone":"PENDING_OWNER_RULE","rounding":"DETERMINISTIC_CENT_RESIDUAL_PENDING"}','2026-01-01T00:00:00Z'),
('GENERATION',1,'{"gen1_rates":{"BASIC_1":0.20,"BASIC_2":0.22,"ADVANCED_1":0.24,"ADVANCED_2":0.26,"PREMIUM":0.30},"gen2_plus_rate":0.05,"direct_and_gen1_stack":false}','2026-01-01T00:00:00Z'),
('CURRENCY',1,'{"marketplace_currency":"PKR","package_plan_currency":"USD","usd_to_pkr_rate":null,"package_checkout_enabled":false}','2026-01-01T00:00:00Z');

-- Read access is scoped by ownership. All sensitive writes and all credits go
-- through verified server-side functions; never expose service_role to browsers.
alter table public.member_profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.package_versions enable row level security;
alter table public.system_config enable row level security;
alter table public.vendor_applications enable row level security;
alter table public.vendors enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.binary_placements enable row level security;
alter table public.package_activations enable row level security;
alter table public.point_ledger enable row level security;
alter table public.binary_cycles enable row level security;
alter table public.binary_member_results enable row level security;
alter table public.bonus_transactions enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.audit_logs enable row level security;

create policy "member reads own profile" on public.member_profiles for select to authenticated
  using ((select auth.uid()) = user_id or private.has_role('admin'));
create policy "member updates own contact fields" on public.member_profiles for update to authenticated
  using ((select auth.uid()) = user_id and status = 'active')
  with check ((select auth.uid()) = user_id and status = 'active');
create policy "user reads own roles" on public.user_roles for select to authenticated
  using ((select auth.uid()) = user_id or private.has_role('admin'));
create policy "active package terms are public" on public.package_versions for select to anon, authenticated
  using (is_active and effective_from <= now() and (effective_to is null or effective_to > now()));
create policy "current public rules are readable" on public.system_config for select to anon, authenticated
  using (effective_to is null or effective_to > now());
create policy "applicant reads own vendor application" on public.vendor_applications for select to authenticated
  using (applicant_user_id=(select auth.uid()) or private.has_role('admin'));
create policy "authenticated user submits one vendor application" on public.vendor_applications for insert to authenticated
  with check (applicant_user_id=(select auth.uid()) and status='pending' and reviewed_by is null and reviewed_at is null);

create policy "active vendors are public" on public.vendors for select to anon, authenticated
  using (status = 'active');
create policy "vendor owner and admins read vendor record" on public.vendors for select to authenticated
  using (owner_user_id = (select auth.uid()) or private.has_role('admin'));
create policy "approved products are public" on public.products for select to anon, authenticated
  using (status = 'approved' and exists(select 1 from public.vendors v where v.id=vendor_id and v.status='active'));
create policy "vendor owner and admins read product records" on public.products for select to authenticated
  using (exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()))
    or private.has_role('admin'));
create policy "vendor creates own draft products" on public.products for insert to authenticated
  with check (status='draft' and exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()) and v.status='active'));
create policy "vendor updates own draft products" on public.products for update to authenticated
  using ((status in ('draft','pending') and exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()) and v.status='active')) or private.has_role('admin'))
  with check ((status in ('draft','pending') and exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()) and v.status='active')) or private.has_role('admin'));

create policy "buyer or admin reads orders" on public.orders for select to authenticated
  using (buyer_id=(select auth.uid()) or private.has_role('admin'));
create policy "buyer or assigned vendor reads order items" on public.order_items for select to authenticated
  using (exists(select 1 from public.orders o where o.id=order_id and o.buyer_id=(select auth.uid()))
    or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()))
    or private.has_role('admin'));

create policy "member reads own placements" on public.binary_placements for select to authenticated
  using (member_id=(select auth.uid()) or parent_id=(select auth.uid()) or private.has_role('admin'));
create policy "member reads own activations" on public.package_activations for select to authenticated
  using (member_id=(select auth.uid()) or private.has_role('admin'));
create policy "member reads own points" on public.point_ledger for select to authenticated
  using (member_id=(select auth.uid()) or private.has_role('admin'));
create policy "admin reads binary cycles" on public.binary_cycles for select to authenticated
  using (private.has_role('admin'));
create policy "member reads own binary results" on public.binary_member_results for select to authenticated
  using (member_id=(select auth.uid()) or private.has_role('admin'));
create policy "member reads own bonuses" on public.bonus_transactions for select to authenticated
  using (beneficiary_id=(select auth.uid()) or private.has_role('admin'));
create policy "member reads own wallet ledger" on public.wallet_ledger for select to authenticated
  using (member_id=(select auth.uid()) or private.has_role('admin'));
create policy "admin reads audit logs" on public.audit_logs for select to authenticated
  using (private.has_role('admin'));

-- Direct browser writes to financial and admin-controlled data are intentionally absent.
revoke all on all tables in schema public from anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select on public.package_versions, public.system_config, public.vendors, public.products to anon, authenticated;
grant select, insert on public.vendor_applications to authenticated;
grant insert, update on public.products to authenticated;
grant select on public.member_profiles, public.user_roles, public.orders, public.order_items,
  public.binary_placements, public.package_activations, public.point_ledger, public.binary_cycles,
  public.binary_member_results, public.bonus_transactions, public.wallet_ledger, public.audit_logs to authenticated;
revoke update on public.member_profiles from anon, authenticated;
grant update(full_name,phone,country_code) on public.member_profiles to authenticated;
revoke update, delete on public.vendor_applications from anon, authenticated;
revoke delete on public.products from anon, authenticated;


-- ===== schema/002_mio_marketplace_rules.sql =====
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


-- ===== schema/003_marketplace_operations.sql =====
-- Marketplace operations. Product, member, and order records remain empty
-- until created from actual business submissions.

alter table public.orders add column if not exists usd_to_pkr_rate numeric(14,6);
alter table public.orders add column if not exists ppv_generated numeric(18,4) not null default 0;

create function public.admin_set_usd_to_pkr_rate(p_rate numeric, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid()); next_version integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_rate is null or p_rate < 1 or p_rate > 10000 then raise exception 'Invalid USD to PKR rate'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason/source is required'; end if;
  select coalesce(max(version),0)+1 into next_version from public.system_config where config_key='CURRENCY';
  update public.system_config set effective_to=now() where config_key='CURRENCY' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
    values('CURRENCY',next_version,jsonb_build_object('marketplace_currency','PKR','package_plan_currency','USD',
      'usd_to_pkr_rate',p_rate,'package_checkout_enabled',true,'rate_source',trim(p_reason)),now(),admin_id);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'USD_PKR_RATE_SET','system_config',jsonb_build_object('version',next_version,'rate',p_rate,'source',trim(p_reason)));
  return next_version;
end;
$$;
revoke all on function public.admin_set_usd_to_pkr_rate(numeric,text) from public, anon;
grant execute on function public.admin_set_usd_to_pkr_rate(numeric,text) to authenticated;

create function public.admin_review_vendor_application(p_application_id uuid, p_approve boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid()); app public.vendor_applications%rowtype; vendor uuid;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select * into app from public.vendor_applications where id=p_application_id for update;
  if app.id is null or app.status <> 'pending' then raise exception 'Pending application not found'; end if;
  update public.vendor_applications set status=case when p_approve then 'active'::public.vendor_status else 'rejected'::public.vendor_status end,
    reviewed_by=admin_id,reviewed_at=now() where id=app.id;
  if p_approve then
    insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,reviewed_by,reviewed_at)
      values(app.applicant_user_id,app.business_name,app.contact_email,app.contact_phone,app.description,'active',admin_id,now())
      on conflict(owner_user_id) do update set business_name=excluded.business_name,contact_email=excluded.contact_email,
        contact_phone=excluded.contact_phone,description=excluded.description,status='active',reviewed_by=admin_id,reviewed_at=now()
      returning id into vendor;
  else
    select id into vendor from public.vendors where owner_user_id=app.applicant_user_id;
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,case when p_approve then 'VENDOR_APPROVED' else 'VENDOR_REJECTED' end,'vendor_application',app.id,
      jsonb_build_object('applicant_id',app.applicant_user_id,'vendor_id',vendor));
  return vendor;
end;
$$;
revoke all on function public.admin_review_vendor_application(uuid,boolean) from public, anon;
grant execute on function public.admin_review_vendor_application(uuid,boolean) to authenticated;

create function public.admin_review_product(p_product_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid());
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  update public.products set status=case when p_approve then 'approved'::public.product_status else 'rejected'::public.product_status end,
    updated_at=now() where id=p_product_id and status in ('draft','pending');
  if not found then raise exception 'Reviewable product not found'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,case when p_approve then 'PRODUCT_APPROVED' else 'PRODUCT_REJECTED' end,'product',p_product_id,
      jsonb_build_object('status',case when p_approve then 'approved' else 'rejected' end));
end;
$$;
revoke all on function public.admin_review_product(uuid,boolean) from public, anon;
grant execute on function public.admin_review_product(uuid,boolean) to authenticated;

create function public.admin_set_company_vendor(p_vendor_id uuid, p_company_owned boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare admin_id uuid := (select auth.uid());
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  update public.vendors set is_company_owned=p_company_owned where id=p_vendor_id and status='active';
  if not found then raise exception 'Active vendor not found'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'COMPANY_VENDOR_CLASSIFIED','vendor',p_vendor_id,jsonb_build_object('is_company_owned',p_company_owned));
end;
$$;
revoke all on function public.admin_set_company_vendor(uuid,boolean) from public, anon;
grant execute on function public.admin_set_company_vendor(uuid,boolean) to authenticated;

create function private.activate_next_ppv_package(p_member_id uuid, p_order_id uuid, p_cumulative_ppv numeric)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  rank_code text[] := array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2'];
  current_code text := private.current_package_code(p_member_id);
  current_rank integer := array_position(rank_code,current_code);
  i integer;
  p public.package_versions%rowtype;
  aid uuid;
  count_activated integer := 0;
  id_key text;
begin
  if current_rank is null then current_rank := 0; end if;
  for i in current_rank+1..4 loop
    select * into p from public.package_versions where package_code=rank_code[i] and is_active
      and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
    if p.package_code is null or p_cumulative_ppv < p.ppv then exit; end if;
    id_key := 'ppv:' || p_order_id::text || ':' || rank_code[i];
    if exists(select 1 from public.package_activations where idempotency_key=id_key) then continue; end if;
    aid := gen_random_uuid();
    insert into public.package_activations(
      id,member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,
      direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
    values(aid,p_member_id,p.package_code,p.version,'SHOPPING_PPV',p_order_id::text,p.base_value,p.company_fee,p.payable_price,
      p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
      'approved',now(),null,id_key);
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values(p_member_id,'PPV',p.ppv,aid,'credit',id_key || ':ppv');
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(p_member_id,'PACKAGE_AUTO_ACTIVATED_PPV','package_activation',aid,
        jsonb_build_object('order_id',p_order_id,'package_code',p.package_code,'ppv_balance',p_cumulative_ppv));
    count_activated := count_activated+1;
  end loop;
  return count_activated;
end;
$$;
revoke all on function private.activate_next_ppv_package(uuid,uuid,numeric) from public, anon, authenticated;

create function public.place_marketplace_order(
  p_items jsonb,
  p_shipping_name text,
  p_shipping_phone text,
  p_shipping_address text,
  p_shipping_city text,
  p_idempotency_key text
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  buyer uuid := (select auth.uid());
  order_id uuid := gen_random_uuid();
  order_code text;
  rate numeric(14,6);
  item record;
  prod public.products%rowtype;
  item_subtotal numeric(14,2) := 0;
  existing_id uuid;
begin
  if buyer is null then raise exception 'Sign in before placing an order'; end if;
  if not exists(select 1 from public.member_profiles where user_id=buyer and status='active') then raise exception 'Active account required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty'; end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines'; end if;
  if length(coalesce(p_idempotency_key,''))<12 then raise exception 'Invalid order request key'; end if;
  select id into existing_id from public.orders where idempotency_key=p_idempotency_key;
  if existing_id is not null then return existing_id; end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_phone,'')))<5
    or length(trim(coalesce(p_shipping_address,'')))<5 or length(trim(coalesce(p_shipping_city,'')))<2 then
    raise exception 'Complete delivery details are required';
  end if;
  select (config_value->>'usd_to_pkr_rate')::numeric into rate from public.system_config
    where config_key='CURRENCY' and effective_to is null order by version desc limit 1;
  if rate is null then raise exception 'Marketplace is waiting for the admin to configure the USD/PKR PPV conversion rate'; end if;

  order_code := 'MIO-' || upper(substr(replace(order_id::text,'-',''),1,10));
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,
    shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate)
  values(order_id,order_code,buyer,0,0,0,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),
    trim(p_shipping_address),trim(p_shipping_city),p_idempotency_key,rate);

  for item in select product_id,quantity from jsonb_to_recordset(p_items) as x(product_id uuid,quantity integer) loop
    if item.quantity is null or item.quantity<1 or item.quantity>99 then raise exception 'Invalid item quantity'; end if;
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status <> 'approved' or prod.stock_quantity < item.quantity then
      raise exception 'A selected product is unavailable or out of stock';
    end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active'; end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity)
      values(order_id,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    item_subtotal := item_subtotal+(prod.price_pkr*item.quantity);
  end loop;
  if item_subtotal<=0 then raise exception 'Basket total must be positive'; end if;
  update public.orders set subtotal_pkr=item_subtotal,total_pkr=item_subtotal where id=order_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(buyer,'MARKETPLACE_ORDER_PLACED','order',order_id,
      jsonb_build_object('order_code',order_code,'subtotal_pkr',item_subtotal,'usd_to_pkr_rate',rate,'ppv_status','pending payment confirmation'));
  return order_id;
end;
$$;
revoke all on function public.place_marketplace_order(jsonb,text,text,text,text,text) from public, anon;
grant execute on function public.place_marketplace_order(jsonb,text,text,text,text,text) to authenticated;

create function public.admin_confirm_order_payment(p_order_id uuid)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  order_row public.orders%rowtype;
  ppv_value numeric(18,4);
  current_ppv numeric(18,4);
  activated integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select * into order_row from public.orders where id=p_order_id for update;
  if order_row.id is null then raise exception 'Order not found'; end if;
  if order_row.payment_status='confirmed' then return order_row.ppv_generated; end if;
  if order_row.payment_status<>'unconfirmed' or order_row.status in ('cancelled','returned') then
    raise exception 'Order is not eligible for payment confirmation';
  end if;
  ppv_value := round(order_row.subtotal_pkr/order_row.usd_to_pkr_rate,4);
  update public.orders set payment_status='confirmed',ppv_generated=ppv_value,updated_at=now() where id=order_row.id;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
    values(order_row.buyer_id,'PPV',ppv_value,order_row.id,'credit','order:' || order_row.id::text || ':ppv')
    on conflict(idempotency_key) do nothing;
  select coalesce(sum(amount),0) into current_ppv from public.point_ledger
    where member_id=order_row.buyer_id and point_type='PPV';
  activated := private.activate_next_ppv_package(order_row.buyer_id,order_row.id,current_ppv);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ORDER_PAYMENT_CONFIRMED','order',order_row.id,
      jsonb_build_object('buyer_id',order_row.buyer_id,'ppv_generated',ppv_value,'cumulative_ppv',current_ppv,'auto_activations',activated));
  return ppv_value;
end;
$$;
revoke all on function public.admin_confirm_order_payment(uuid) from public, anon;
grant execute on function public.admin_confirm_order_payment(uuid) to authenticated;

-- No direct browser writes to inventory, orders, activation, or financial ledgers.
revoke insert, update, delete on public.orders, public.order_items from anon, authenticated;
revoke insert, update, delete on public.point_ledger, public.package_activations from anon, authenticated;


-- ===== schema/004_transfer_by_member_code.sql =====
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


-- ===== schema/005_phase1_direct_generation.sql =====
-- Direct and Generation payouts use the source activation BV and the package
-- rates in the activation snapshot. They credit MIO Points through the ledger.

alter table public.mio_ledger add column if not exists bonus_transaction_id uuid references public.bonus_transactions(id);
alter table public.mio_ledger drop constraint if exists mio_ledger_action_check;
alter table public.mio_ledger add constraint mio_ledger_action_check
  check (action in ('admin_mint','admin_burn','transfer_in','transfer_out','package_activation','bonus_credit'));
alter table public.mio_ledger drop constraint if exists mio_ledger_amount_check;
alter table public.mio_ledger add constraint mio_ledger_amount_check
  check ((action in ('admin_mint','transfer_in','bonus_credit') and amount > 0)
    or (action in ('admin_burn','transfer_out','package_activation') and amount < 0));
alter table public.mio_ledger drop constraint if exists mio_ledger_check2;
alter table public.mio_ledger drop constraint if exists mio_ledger_check1;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check
  check ((action in ('package_activation','bonus_credit') and activation_id is not null)
    or (action not in ('package_activation','bonus_credit') and activation_id is null));

create function private.credit_activation_bonuses(p_activation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  act public.package_activations%rowtype;
  direct_sponsor uuid;
  beneficiary uuid;
  receiver_activation public.package_activations%rowtype;
  recipient record;
  gen_depth integer;
  gen_limit integer;
  gen1_rate numeric(10,8);
  gen2_rate numeric(10,8) := 0.05;
  stack_gen1 boolean := false;
  applied integer := 0;
  txn_id uuid;
  payout numeric(18,4);
  rate numeric(10,8);
  key text;
begin
  select * into act from public.package_activations where id=p_activation_id;
  if act.id is null or act.status<>'approved' then return 0; end if;
  select (config_value->>'direct_and_gen1_stack')::boolean,
         coalesce((config_value->>'gen2_plus_rate')::numeric,0.05)
    into stack_gen1,gen2_rate
    from public.system_config where config_key='GENERATION' and effective_to is null
    order by version desc limit 1;
  stack_gen1 := coalesce(stack_gen1,false);
  gen2_rate := coalesce(gen2_rate,0.05);
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=act.member_id;

  if direct_sponsor is not null and exists(select 1 from public.member_profiles where user_id=direct_sponsor and status='active')
     and private.current_package_code(direct_sponsor) is not null then
    payout := round(act.bv*act.direct_rate,4);
    if payout>0 then
      key := 'direct:' || act.id::text;
      insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,qualifying_base,rate,gross_amount,
        payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
      values(direct_sponsor,'direct',act.id,act.bv,act.direct_rate,payout,payout,'MIO','phase1-direct-v1',
        jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'rate',act.direct_rate,'calculation','BV x direct rate'),
        'posted',key) on conflict(idempotency_key) do nothing returning id into txn_id;
      if txn_id is not null then
        update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=direct_sponsor;
        insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
          values(direct_sponsor,payout,'bonus_credit',act.id,txn_id,'Direct bonus','bonus:'||txn_id::text);
        applied := applied+1;
      end if;
    end if;
  end if;

  -- Loop over a bounded sponsor chain. Depth is capped by the configured maximum.
  for recipient in
    with recursive uplines(user_id,sponsor_id,depth,path) as (
      select m.user_id,m.sponsor_id,1,array[m.user_id] from public.member_profiles m where m.user_id=act.member_id
      union all
      select parent.user_id,parent.sponsor_id,u.depth+1,u.path||parent.user_id
        from uplines u join public.member_profiles parent on parent.user_id=u.sponsor_id
        where u.sponsor_id is not null and u.depth<10 and not parent.user_id=any(u.path)
    )
    select u.sponsor_id as member_id,u.depth as generation
      from uplines u where u.sponsor_id is not null order by u.depth
  loop
    beneficiary := recipient.member_id;
    gen_depth := recipient.generation;
    if not exists(select 1 from public.member_profiles where user_id=beneficiary and status='active') then continue; end if;
    select a into receiver_activation
      from public.package_activations a join public.package_versions pv
        on pv.package_code=a.package_code and pv.version=a.package_version
      where a.member_id=beneficiary and a.status='approved'
      order by a.activated_at desc nulls last,a.requested_at desc limit 1;
    select pv.max_generations,pv.generation1_rate into gen_limit,gen1_rate
      from public.package_versions pv where pv.package_code=receiver_activation.package_code
        and pv.version=receiver_activation.package_version;
    if receiver_activation.id is null or gen_depth>gen_limit then continue; end if;
    if gen_depth=1 and not stack_gen1 then continue; end if;
    rate := case when gen_depth=1 then gen1_rate else gen2_rate end;
    payout := round(act.bv*rate,4);
    if payout<=0 then continue; end if;
    key := 'generation:'||act.id::text||':'||beneficiary::text||':'||gen_depth::text;
    insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,
      gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
    values(beneficiary,'generation',act.id,gen_depth,act.bv,rate,payout,payout,'MIO','phase1-generation-v1',
      jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'beneficiary_package',receiver_activation.package_code,
        'generation',gen_depth,'rate',rate,'direct_gen1_stack',stack_gen1), 'posted',key)
    on conflict(idempotency_key) do nothing returning id into txn_id;
    if txn_id is not null then
      update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=beneficiary;
      insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
        values(beneficiary,payout,'bonus_credit',act.id,txn_id,'Generation bonus','bonus:'||txn_id::text);
      applied := applied+1;
    end if;
  end loop;
  return applied;
end;
$$;
revoke all on function private.credit_activation_bonuses(uuid) from public, anon, authenticated;

create or replace function private.activate_next_ppv_package(p_member_id uuid, p_order_id uuid, p_cumulative_ppv numeric)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  rank_code text[] := array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2'];
  current_code text := private.current_package_code(p_member_id);
  current_rank integer := array_position(rank_code,current_code);
  i integer;
  p public.package_versions%rowtype;
  aid uuid;
  count_activated integer := 0;
  id_key text;
begin
  -- Premium never auto-activates or auto-upgrades through PPV.
  if current_code='PREMIUM' then return 0; end if;
  if current_rank is null then current_rank := 0; end if;
  for i in current_rank+1..4 loop
    select * into p from public.package_versions where package_code=rank_code[i] and is_active
      and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
    if p.package_code is null or p_cumulative_ppv < p.ppv then exit; end if;
    id_key := 'ppv:' || p_order_id::text || ':' || rank_code[i];
    if exists(select 1 from public.package_activations where idempotency_key=id_key) then continue; end if;
    aid := gen_random_uuid();
    insert into public.package_activations(
      id,member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,
      direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
    values(aid,p_member_id,p.package_code,p.version,'SHOPPING_PPV',p_order_id::text,p.base_value,p.company_fee,p.payable_price,
      p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
      'approved',now(),null,id_key);
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values(p_member_id,'PPV',p.ppv,aid,'credit',id_key || ':ppv');
    perform private.credit_activation_bonuses(aid);
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(p_member_id,'PACKAGE_AUTO_ACTIVATED_PPV','package_activation',aid,
        jsonb_build_object('order_id',p_order_id,'package_code',p.package_code,'ppv_balance',p_cumulative_ppv));
    count_activated := count_activated+1;
  end loop;
  return count_activated;
end;
$$;
revoke all on function private.activate_next_ppv_package(uuid,uuid,numeric) from public, anon, authenticated;

create or replace function public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
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
  perform private.credit_activation_bonuses(activation);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,jsonb_build_object('package_code',p.package_code,'payable_mio',p.payable_price,'ppv_credited',p.ppv));
  return activation;
end;
$$;
revoke all on function public.activate_package_with_mio(text,text) from public, anon;
grant execute on function public.activate_package_with_mio(text,text) to authenticated;

-- Backfill no rows: there have been no member package activations yet.


-- ===== schema/006_binary_placement_and_pool.sql =====
-- Binary placement and 35% weekly Binary Pool Share.
-- Qualification for pool participation is an active package plus a completed
-- 50-left/50-right share. A weekly cycle is created and closed by an admin.

alter table public.mio_ledger add column if not exists cycle_id uuid references public.binary_cycles(id);
alter table public.mio_ledger drop constraint if exists mio_ledger_activation_source_check;
alter table public.mio_ledger add constraint mio_ledger_bonus_source_check
  check ((action='package_activation' and activation_id is not null and bonus_transaction_id is null and cycle_id is null)
    or (action='bonus_credit' and bonus_transaction_id is not null
      and ((activation_id is not null and cycle_id is null) or (activation_id is null and cycle_id is not null)))
    or (action not in ('package_activation','bonus_credit') and activation_id is null and bonus_transaction_id is null and cycle_id is null));

create function private.credit_binary_volume(p_activation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  act public.package_activations%rowtype;
  current_member uuid;
  parent_member uuid;
  member_side text;
  depth integer := 0;
  credited integer := 0;
begin
  select * into act from public.package_activations where id=p_activation_id and status='approved';
  if act.id is null or act.bp<=0 then return 0; end if;
  current_member := act.member_id;
  loop
    select parent_id,side into parent_member,member_side from public.binary_placements where member_id=current_member;
    exit when parent_member is null;
    insert into public.point_ledger(member_id,point_type,amount,side,source_activation_id,entry_kind,idempotency_key)
      values(parent_member,'BP',act.bp,member_side,act.id,'credit',
        'bp:'||act.id::text||':'||parent_member::text)
      on conflict(idempotency_key) do nothing;
    if found then credited := credited+1; end if;
    current_member := parent_member;
    depth := depth+1;
    if depth>=100 then raise exception 'Binary placement depth limit reached'; end if;
  end loop;
  return credited;
end;
$$;
revoke all on function private.credit_binary_volume(uuid) from public, anon, authenticated;

create function public.admin_place_binary_member(p_member_code text, p_parent_code text, p_side text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  member uuid;
  parent uuid;
  activation_id uuid;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select user_id into member from public.member_profiles
    where upper(member_code)=upper(trim(p_member_code)) or upper(referral_code)=upper(trim(p_member_code)) limit 1;
  if member is null then raise exception 'Member code not found'; end if;
  if exists(select 1 from public.binary_placements where member_id=member) then raise exception 'Member already has a binary placement'; end if;
  if nullif(trim(coalesce(p_parent_code,'')),'') is null then
    if p_side is not null and trim(p_side)<>'' then raise exception 'Root placement has no side'; end if;
    if exists(select 1 from public.binary_placements where parent_id is null) then raise exception 'A binary root already exists'; end if;
    insert into public.binary_placements(member_id,parent_id,side,placed_by) values(member,null,null,admin_id);
  else
    select user_id into parent from public.member_profiles
      where upper(member_code)=upper(trim(p_parent_code)) or upper(referral_code)=upper(trim(p_parent_code)) limit 1;
    if parent is null then raise exception 'Parent code not found'; end if;
    if parent=member then raise exception 'A member cannot be placed under themselves'; end if;
    if not exists(select 1 from public.binary_placements where member_id=parent) then raise exception 'Place the parent before placing a child'; end if;
    if upper(trim(coalesce(p_side,''))) not in ('LEFT','RIGHT') then raise exception 'Choose LEFT or RIGHT'; end if;
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
      values(member,parent,upper(trim(p_side)),admin_id);
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'BINARY_MEMBER_PLACED','binary_placement',member,
      jsonb_build_object('parent_id',parent,'side',upper(nullif(trim(p_side),''))));
  -- If package activation preceded placement, now backfill this member's BP.
  for activation_id in select id from public.package_activations where member_id=member and status='approved' loop
    perform private.credit_binary_volume(activation_id);
  end loop;
  return member;
end;
$$;
revoke all on function public.admin_place_binary_member(text,text,text) from public, anon;
grant execute on function public.admin_place_binary_member(text,text,text) to authenticated;

create function public.admin_close_binary_cycle(p_cycle_code text, p_starts_at timestamptz, p_ends_at timestamptz, p_timezone text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  cycle uuid := gen_random_uuid();
  eligible numeric(18,4);
  pool numeric(18,8);
  share_count bigint;
  m record;
  previous_left numeric(18,4);
  previous_right numeric(18,4);
  new_left numeric(18,4);
  new_right numeric(18,4);
  shares bigint;
  gross numeric(18,8);
  member_pay numeric(18,8);
  retention numeric(18,8);
  txn uuid;
  key text;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at then
    raise exception 'A cycle code and valid start/end are required';
  end if;
  if exists(select 1 from public.binary_cycles c where c.status not in ('reversed')
    and c.starts_at<p_ends_at and c.ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
  if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;

  select coalesce(sum(base_value),0) into eligible from public.package_activations
    where status='approved' and activated_at>=p_starts_at and activated_at<p_ends_at;
  pool := round(eligible*0.35,8);
  insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
    values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,trim(coalesce(p_timezone,'Asia/Karachi')),eligible,0.35,pool,'open');

  -- First pass counts full 50/50 shares after the latest earlier carry.
  with active_package as (
    select distinct on (a.member_id) a.member_id,a.package_code,a.package_version,pv.binary_entitlement
      from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version
      join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
      where a.status='approved' and a.activated_at<p_ends_at
      order by a.member_id,a.activated_at desc nulls last,a.requested_at desc
  ), prior as (
    select ap.member_id,
      coalesce((select r.carry_left from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
        where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) left_carry,
      coalesce((select r.carry_right from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
        where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) right_carry
    from active_package ap
  ), volume as (
    select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) left_new,
      coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) right_new
    from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
    where pl.point_type='BP' and a.status='approved' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at
    group by pl.member_id
  )
  select coalesce(sum(floor(least(pr.left_carry+coalesce(v.left_new,0),pr.right_carry+coalesce(v.right_new,0))/50)::bigint),0)
    into share_count from prior pr left join volume v on v.member_id=pr.member_id;

  if share_count=0 then
    update public.binary_cycles set total_completed_shares=0,status='unallocated',closed_at=now() where id=cycle;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'pool',pool,'shares',0));
    return cycle;
  end if;
  update public.binary_cycles set total_completed_shares=share_count,gross_share_value=pool/share_count,status='frozen' where id=cycle;

  for m in
    with active_package as (
      select distinct on (a.member_id) a.member_id,a.package_code,a.package_version,pv.binary_entitlement
        from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version
        join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
        where a.status='approved' and a.activated_at<p_ends_at
        order by a.member_id,a.activated_at desc nulls last,a.requested_at desc
    ), prior as (
      select ap.*,
        coalesce((select r.carry_left from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
          where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) left_carry,
        coalesce((select r.carry_right from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
          where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) right_carry
      from active_package ap
    ), volume as (
      select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) left_new,
        coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) right_new
      from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
      where pl.point_type='BP' and a.status='approved' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at
      group by pl.member_id
    ), balances as (
      select pr.member_id,pr.package_code,pr.package_version,pr.binary_entitlement,
        pr.left_carry+coalesce(v.left_new,0) left_available,pr.right_carry+coalesce(v.right_new,0) right_available
      from prior pr left join volume v on v.member_id=pr.member_id
    )
    select *,floor(least(left_available,right_available)/50)::bigint completed from balances
  loop
    shares := m.completed;
    gross := round((pool/share_count)*shares,8);
    member_pay := round(gross*m.binary_entitlement,4);
    retention := gross-member_pay;
    insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,
      completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,
      qualification_snapshot)
    values(cycle,m.member_id,m.package_code,m.package_version,m.left_available,m.right_available,shares,m.binary_entitlement,
      gross,member_pay,retention,shares*50,shares*50,m.left_available-(shares*50),m.right_available-(shares*50),
      jsonb_build_object('qualification','active_package_and_full_share','pool_rate',0.35,'share_points_each_side',50));
    if member_pay>0 then
      key := 'binary:'||cycle::text||':'||m.member_id::text;
      insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,
        currency,formula_version,calculation_trace,status,idempotency_key)
      values(m.member_id,'binary_pool_share',cycle,gross,m.binary_entitlement,gross,member_pay,'MIO','phase1-binary-pool-v1',
        jsonb_build_object('completed_shares',shares,'entitlement',m.binary_entitlement,'gross_share_value',pool/share_count,
          'member_amount',member_pay,'company_retention',retention), 'posted',key)
      on conflict(idempotency_key) do nothing returning id into txn;
      if txn is not null then
        update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
        insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)
          values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
      end if;
    end if;
  end loop;
  update public.binary_cycles set status='posted',closed_at=now() where id=cycle;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,
      jsonb_build_object('eligible_base',eligible,'pool_rate',0.35,'pool',pool,'completed_shares',share_count,'gross_share_value',pool/share_count));
  return cycle;
end;
$$;
revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) from public, anon;
grant execute on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) to authenticated;

create function private.on_package_activation_binary_volume()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status='approved' then perform private.credit_binary_volume(new.id); end if;
  return new;
end;
$$;
revoke all on function private.on_package_activation_binary_volume() from public, anon, authenticated;
create trigger package_activation_binary_volume
after insert on public.package_activations for each row execute function private.on_package_activation_binary_volume();



-- ===== schema/007_signup_referrals_and_consent.sql =====
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


-- ===== schema/008_policy_and_index_cleanup.sql =====
-- Keep relationship lookups indexed for the expected early member scale.
create index if not exists audit_logs_actor_idx on public.audit_logs(actor_id);
create index if not exists binary_member_results_member_idx on public.binary_member_results(member_id);
create index if not exists binary_member_results_package_idx on public.binary_member_results(package_code,package_version);
create index if not exists binary_placements_placed_by_idx on public.binary_placements(placed_by);
create index if not exists bonus_transactions_cycle_idx on public.bonus_transactions(cycle_id);
create index if not exists bonus_transactions_activation_idx on public.bonus_transactions(source_activation_id);
create index if not exists featured_products_selected_by_idx on public.featured_products(selected_by);
create index if not exists mio_ledger_activation_idx on public.mio_ledger(activation_id);
create index if not exists mio_ledger_bonus_idx on public.mio_ledger(bonus_transaction_id);
create index if not exists mio_ledger_counterparty_idx on public.mio_ledger(counterparty_id);
create index if not exists mio_ledger_cycle_idx on public.mio_ledger(cycle_id);
create index if not exists order_items_order_idx on public.order_items(order_id);
create index if not exists order_items_product_idx on public.order_items(product_id);
create index if not exists package_activations_approver_idx on public.package_activations(approved_by);
create index if not exists package_activations_package_idx on public.package_activations(package_code,package_version);
create index if not exists point_ledger_activation_idx on public.point_ledger(source_activation_id);
create index if not exists point_ledger_order_idx on public.point_ledger(source_order_id);
create index if not exists system_config_creator_idx on public.system_config(created_by);
create index if not exists vendor_applications_reviewer_idx on public.vendor_applications(reviewed_by);
create index if not exists vendors_reviewer_idx on public.vendors(reviewed_by);
create index if not exists wallet_ledger_bonus_idx on public.wallet_ledger(bonus_transaction_id);

drop policy if exists "active vendors are public" on public.vendors;
drop policy if exists "vendor owner and admins read vendor record" on public.vendors;
create policy "active vendors are public" on public.vendors for select to anon using (status='active');
create policy "authenticated reads public or own vendors" on public.vendors for select to authenticated
  using (status='active' or owner_user_id=(select auth.uid()) or private.has_role('admin'));

drop policy if exists "approved products are public" on public.products;
drop policy if exists "vendor owner and admins read product records" on public.products;
create policy "approved products are public" on public.products for select to anon
  using (status='approved' and exists(select 1 from public.vendors v where v.id=vendor_id and v.status='active'));
create policy "authenticated reads public or own products" on public.products for select to authenticated
  using ((status='approved' and exists(select 1 from public.vendors v where v.id=vendor_id and v.status='active'))
    or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()))
    or private.has_role('admin'));

revoke execute on function private.current_package_code(uuid) from authenticated;

create or replace function public.my_direct_referrals()
returns table(member_code text,full_name text,created_at timestamptz,status public.account_status)
language sql stable security definer set search_path = '' as $$
  select mp.member_code,mp.full_name,mp.created_at,mp.status
  from public.member_profiles mp
  where (select auth.uid()) is not null and mp.sponsor_id=(select auth.uid())
  order by mp.created_at desc;
$$;
revoke all on function public.my_direct_referrals() from public, anon;
grant execute on function public.my_direct_referrals() to authenticated;


-- ===== schema/009_activation_point_assignment.sql =====
-- Activation-assigned points beyond PPV. PPV itself remains sourced either
-- by the payment/MIO activation routine or by a paid marketplace order.
create function private.assign_activation_points()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status='approved' then
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values
        (new.member_id,'BV',new.bv,new.id,'credit','activation:'||new.id::text||':BV'),
        (new.member_id,'DP',new.dp,new.id,'credit','activation:'||new.id::text||':DP'),
        (new.member_id,'GP',new.gp,new.id,'credit','activation:'||new.id::text||':GP'),
        (new.member_id,'BRP',new.brp,new.id,'credit','activation:'||new.id::text||':BRP')
      on conflict do nothing;
    perform private.credit_activation_bonuses(new.id);
  end if;
  return new;
end;
$$;
revoke all on function private.assign_activation_points() from public, anon, authenticated;
create trigger package_activation_point_assignments
after insert on public.package_activations for each row execute function private.assign_activation_points();


-- ===== schema/010_verified_business_rules.sql =====
CREATE OR REPLACE FUNCTION public.mio_transfer(p_recipient_id uuid, p_amount numeric, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 or p_amount <> round(p_amount,4) then raise exception 'Invalid MIO amount'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 or length(p_idempotency_key) > 100 then raise exception 'Invalid idempotency key'; end if;

  perform pg_advisory_xact_lock(hashtextextended('mio-request:'||sender_id::text||':'||p_idempotency_key,0));
  if not exists(select 1 from public.member_profiles where user_id=sender_id and status='active') or not exists(select 1 from public.member_profiles where user_id=p_recipient_id and status='active') then raise exception 'Both accounts must be active'; end if;
  select transfer_id into existing_transfer from public.mio_ledger
    where idempotency_key = sender_id::text || ':' || p_idempotency_key || ':out';
  if existing_transfer is not null then return existing_transfer; end if;

  select private.has_role('admin') into sender_admin;
  select exists(select 1 from public.user_roles r where r.user_id=p_recipient_id and r.role='admin')
    into recipient_admin;
  sender_premium := coalesce(private.current_package_code(sender_id) = 'PREMIUM',false);
  recipient_premium := coalesce(private.current_package_code(p_recipient_id) = 'PREMIUM',false);
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
  if wallet_balance is null or not exists(select 1 from public.mio_wallet_accounts where member_id=p_recipient_id) then raise exception 'Wallet not initialized'; end if;
  if wallet_balance < p_amount then raise exception 'Insufficient MIO balance'; end if;

  update public.mio_wallet_accounts set balance = balance - p_amount, updated_at = now() where member_id = sender_id;
  update public.mio_wallet_accounts set balance = balance + p_amount, updated_at = now() where member_id = p_recipient_id;
  insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,idempotency_key)
    values (sender_id,-p_amount,'transfer_out',p_recipient_id,transfer_key,sender_id::text || ':' || p_idempotency_key || ':out'),
           (p_recipient_id,p_amount,'transfer_in',sender_id,transfer_key,sender_id::text || ':' || p_idempotency_key || ':in');
  return transfer_key;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_mint_own_mio(p_amount numeric, p_reason text, p_idempotency_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid()); new_balance numeric(20,4);
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 or p_amount <> round(p_amount,4) or p_amount > 1000000000 then raise exception 'Invalid MIO amount'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason is required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_mint_own_mio:'||admin_id::text||':'||p_idempotency_key,0));
  if exists(select 1 from public.mio_ledger where member_id=admin_id and idempotency_key=admin_id::text||':'||p_idempotency_key) then
    return (select balance from public.mio_wallet_accounts where member_id=admin_id);
  end if;
  update public.mio_wallet_accounts set balance = balance + p_amount, updated_at = now()
    where member_id = admin_id returning balance into new_balance;
  if new_balance is null then raise exception 'Admin wallet is not initialized'; end if;
  insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key)
    values (admin_id,p_amount,'admin_mint',trim(p_reason),admin_id::text||':'||p_idempotency_key);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ADMIN_MIO_MINT','mio_wallet',admin_id,jsonb_build_object('amount',p_amount,'reason',trim(p_reason),'balance',new_balance));
  return new_balance;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_burn_own_mio(p_amount numeric, p_reason text, p_idempotency_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid()); new_balance numeric(20,4);
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 or p_amount <> round(p_amount,4) then raise exception 'Invalid MIO amount'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason is required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_burn_own_mio:'||admin_id::text||':'||p_idempotency_key,0));
  if exists(select 1 from public.mio_ledger where member_id=admin_id and idempotency_key=admin_id::text||':'||p_idempotency_key) then
    return (select balance from public.mio_wallet_accounts where member_id=admin_id);
  end if;
  update public.mio_wallet_accounts set balance = balance - p_amount, updated_at = now()
    where member_id = admin_id and balance >= p_amount returning balance into new_balance;
  if new_balance is null then raise exception 'Insufficient admin MIO balance'; end if;
  insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key)
    values (admin_id,-p_amount,'admin_burn',trim(p_reason),admin_id::text||':'||p_idempotency_key);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ADMIN_MIO_BURN','mio_wallet',admin_id,jsonb_build_object('amount',p_amount,'reason',trim(p_reason),'balance',new_balance));
  return new_balance;
end;
$function$;

CREATE OR REPLACE FUNCTION public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform pg_advisory_xact_lock(hashtextextended('package-member:'||member::text,0));
  select id into activation from public.package_activations where member_id=member and idempotency_key=member::text||':'||p_idempotency_key;
  if activation is not null then return activation; end if;
  activation := gen_random_uuid();
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
    'approved',now(),member,member::text||':'||p_idempotency_key);
  insert into public.mio_ledger(member_id,amount,action,activation_id,idempotency_key)
    values(member,-p.payable_price,'package_activation',activation,member::text||':'||p_idempotency_key || ':mio');
  insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
    values(member,'PPV',p.ppv,activation,'credit',member::text||':'||p_idempotency_key || ':ppv');
  perform private.credit_activation_bonuses(activation);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,jsonb_build_object('package_code',p.package_code,'payable_mio',p.payable_price,'ppv_credited',p.ppv));
  return activation;
end;
$function$;

CREATE OR REPLACE FUNCTION private.activate_next_ppv_package(p_member_id uuid, p_order_id uuid, p_cumulative_ppv numeric)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rank_code text[] := array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2'];
  current_code text := private.current_package_code(p_member_id);
  current_rank integer := array_position(rank_code,current_code);
  i integer;
  p public.package_versions%rowtype;
  aid uuid;
  count_activated integer := 0;
  id_key text;
begin
  perform pg_advisory_xact_lock(hashtextextended('package-member:'||p_member_id::text,0));
  current_code := private.current_package_code(p_member_id);
  current_rank := array_position(rank_code,current_code);
  select coalesce(sum(amount),0) into p_cumulative_ppv from public.point_ledger where member_id=p_member_id and point_type='PPV';
  -- Premium never auto-activates or auto-upgrades through PPV.
  if current_code='PREMIUM' then return 0; end if;
  if current_rank is null then current_rank := 0; end if;
  for i in current_rank+1..4 loop
    select * into p from public.package_versions where package_code=rank_code[i] and is_active
      and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
    if p.package_code is null or p_cumulative_ppv < p.ppv then exit; end if;
    id_key := 'ppv:' || p_order_id::text || ':' || rank_code[i];
    if exists(select 1 from public.package_activations where idempotency_key=id_key) then continue; end if;
    aid := gen_random_uuid();
    insert into public.package_activations(
      id,member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,
      direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
    values(aid,p_member_id,p.package_code,p.version,'SHOPPING_PPV',p_order_id::text,p.base_value,p.company_fee,p.payable_price,
      p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
      'approved',now(),null,id_key);
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values(p_member_id,'PPV',p.ppv,aid,'credit',id_key || ':ppv');
    perform private.credit_activation_bonuses(aid);
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(p_member_id,'PACKAGE_AUTO_ACTIVATED_PPV','package_activation',aid,
        jsonb_build_object('order_id',p_order_id,'package_code',p.package_code,'ppv_balance',p_cumulative_ppv));
    p_cumulative_ppv := p_cumulative_ppv+p.ppv;
    count_activated := count_activated+1;
  end loop;
  return count_activated;
end;
$function$;

CREATE OR REPLACE FUNCTION public.place_marketplace_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  buyer uuid := (select auth.uid());
  order_id uuid := gen_random_uuid();
  order_code text;
  rate numeric(14,6);
  item record;
  prod public.products%rowtype;
  item_subtotal numeric(14,2) := 0;
  existing_id uuid;
begin
  if buyer is null then raise exception 'Sign in before placing an order'; end if;
  if not exists(select 1 from public.member_profiles where user_id=buyer and status='active') then raise exception 'Active account required'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty'; end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines'; end if;
  if length(coalesce(p_idempotency_key,''))<12 then raise exception 'Invalid order request key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order:'||buyer::text||':'||p_idempotency_key,0));
  select id into existing_id from public.orders where buyer_id=buyer and idempotency_key=buyer::text||':'||p_idempotency_key;
  if existing_id is not null then return existing_id; end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_phone,'')))<5
    or length(trim(coalesce(p_shipping_address,'')))<5 or length(trim(coalesce(p_shipping_city,'')))<2 then
    raise exception 'Complete delivery details are required';
  end if;
  select (config_value->>'usd_to_pkr_rate')::numeric into rate from public.system_config
    where config_key='CURRENCY' and effective_to is null order by version desc limit 1;
  if rate is null then raise exception 'Marketplace is waiting for the admin to configure the USD/PKR PPV conversion rate'; end if;

  order_code := 'MIO-' || upper(substr(replace(order_id::text,'-',''),1,10));
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,
    shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate)
  values(order_id,order_code,buyer,0,0,0,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),
    trim(p_shipping_address),trim(p_shipping_city),buyer::text||':'||p_idempotency_key,rate);

  if exists(select 1 from jsonb_to_recordset(p_items) as x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity<1 or quantity>99) then raise exception 'Invalid basket line'; end if;
  for item in select product_id,sum(quantity)::integer as quantity from jsonb_to_recordset(p_items) as x(product_id uuid,quantity integer) group by product_id order by product_id loop
    if item.quantity is null or item.quantity<1 or item.quantity>99 then raise exception 'Invalid item quantity'; end if;
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status <> 'approved' or prod.stock_quantity < item.quantity then
      raise exception 'A selected product is unavailable or out of stock';
    end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active'; end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity)
      values(order_id,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    item_subtotal := item_subtotal+(prod.price_pkr*item.quantity);
  end loop;
  if item_subtotal<=0 then raise exception 'Basket total must be positive'; end if;
  update public.orders set subtotal_pkr=item_subtotal,total_pkr=item_subtotal where id=order_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(buyer,'MARKETPLACE_ORDER_PLACED','order',order_id,
      jsonb_build_object('order_code',order_code,'subtotal_pkr',item_subtotal,'usd_to_pkr_rate',rate,'ppv_status','pending payment confirmation'));
  return order_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_usd_to_pkr_rate(p_rate numeric, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid()); next_version integer; v_now timestamptz:=clock_timestamp();
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_rate is null or p_rate < 1 or p_rate > 10000 then raise exception 'Invalid USD to PKR rate'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason/source is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mio-fx-config',0));
  select coalesce(max(version),0)+1 into next_version from public.system_config where config_key='CURRENCY';
  update public.system_config set effective_to=v_now where config_key='CURRENCY' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
    values('CURRENCY',next_version,jsonb_build_object('marketplace_currency','PKR','package_plan_currency','USD',
      'usd_to_pkr_rate',p_rate,'package_checkout_enabled',true,'rate_source',trim(p_reason)),v_now,admin_id);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'USD_PKR_RATE_SET','system_config',jsonb_build_object('version',next_version,'rate',p_rate,'source',trim(p_reason)));
  return next_version;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_featured_products(p_product_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform pg_advisory_xact_lock(hashtextextended('mio-featured-products',0));
  delete from public.featured_products;
  insert into public.featured_products(position,product_id,selected_by)
    select ordinality::smallint, product_id, admin_id from unnest(coalesce(p_product_ids,'{}'::uuid[])) with ordinality u(product_id,ordinality);
  n := coalesce(array_length(p_product_ids,1),0);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'FEATURED_PRODUCTS_SET','featured_products',jsonb_build_object('count',n,'product_ids',p_product_ids));
  return n;
end;
$function$;
CREATE OR REPLACE FUNCTION private.current_package_code(p_member_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.package_code
  from public.package_activations a
  where a.member_id = p_member_id and a.status = 'approved'
  order by a.base_value desc, a.activated_at desc nulls last, a.requested_at desc
  limit 1;
$function$;

create or replace function public.my_account_totals()
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object(
 'ppv',coalesce((select sum(amount) from public.point_ledger where member_id=auth.uid() and point_type='PPV'),0),
 'direct',coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=auth.uid() and status='posted' and method='direct'),0),
 'generation',coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=auth.uid() and status='posted' and method='generation'),0),
 'binary_pool_share',coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=auth.uid() and status='posted' and method='binary_pool_share'),0));
$$;
revoke all on function public.my_account_totals() from public,anon;
grant execute on function public.my_account_totals() to authenticated;

create or replace function public.admin_close_binary_cycle(p_cycle_code text,p_starts_at timestamptz,p_ends_at timestamptz,p_timezone text)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 admin_id uuid:=auth.uid(); cycle uuid:=gen_random_uuid(); eligible numeric; pool numeric;
 share_count bigint; m record; gross numeric; member_pay numeric; allocated numeric:=0;
 remainder numeric; residual_recipient uuid; txn uuid; key text;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at or p_ends_at>now() then raise exception 'Choose a completed period with valid start/end'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
 if exists(select 1 from public.binary_cycles where status<>'reversed' and starts_at<p_ends_at and ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated') and ends_at>p_starts_at) then raise exception 'Close binary cycles in chronological order'; end if;
 if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated')) and p_starts_at<>(select max(ends_at) from public.binary_cycles where status in ('posted','unallocated')) then raise exception 'Start the cycle at the previous cycle end'; end if;
 select coalesce(sum(base_value),0) into eligible from public.package_activations where status='approved' and activated_at>=p_starts_at and activated_at<p_ends_at;
 pool:=round(eligible*0.35,4);
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
 values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,p_timezone,eligible,0.35,pool,'open');
 -- Cumulative volume minus all previously consumed volume also includes late placements,
 -- and retains both sides even in a zero-share week.
 for m in
 with active_package as (
 select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,a.binary_entitlement
 from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
 where a.status='approved' and a.activated_at<p_ends_at
 order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
 ), volume as (
 select pl.member_id,
 coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,
 coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
 from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
 where pl.point_type='BP' and a.status='approved' and a.activated_at<p_ends_at and pl.created_at<=now()
 group by pl.member_id
 ), consumed as (
 select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r
 from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
 where c.status in ('posted','unallocated') and c.ends_at<=p_starts_at group by r.member_id
 )
 select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) l,greatest(coalesce(v.r,0)-coalesce(c.r,0),0) r
 from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 loop
 insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)
 values(cycle,m.member_id,m.package_code,m.package_version,m.l,m.r,floor(least(m.l,m.r)/50)::bigint,m.binary_entitlement,0,0,0,
 floor(least(m.l,m.r)/50)*50,floor(least(m.l,m.r)/50)*50,
 m.l-floor(least(m.l,m.r)/50)*50,m.r-floor(least(m.l,m.r)/50)*50,
 jsonb_build_object('qualification','active_package_and_full_share','pool_rate',0.35,'share_points_each_side',50,'precision',4));
 end loop;
 select coalesce(sum(completed_shares),0) into share_count from public.binary_member_results where cycle_id=cycle;
 if share_count=0 then
 update public.binary_cycles set status='unallocated',closed_at=now() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'pool',pool,'shares',0));
 return cycle;
 end if;
 -- Largest remainder at 0.0001 MIO precision, stable member UUID tie-break.
 update public.binary_member_results set gross_amount=trunc(pool*completed_shares/share_count,4),company_retention=trunc(pool*completed_shares/share_count,4) where cycle_id=cycle;
 select pool-sum(gross_amount) into remainder from public.binary_member_results where cycle_id=cycle;
 for residual_recipient in select member_id from public.binary_member_results where cycle_id=cycle and completed_shares>0
 order by (pool*completed_shares/share_count-trunc(pool*completed_shares/share_count,4)) desc,member_id
 limit round(remainder*10000)::integer
 loop
 update public.binary_member_results set gross_amount=gross_amount+0.0001,company_retention=company_retention+0.0001 where cycle_id=cycle and member_id=residual_recipient;
 end loop;
 for m in select * from public.binary_member_results where cycle_id=cycle order by member_id loop
 gross:=m.gross_amount; member_pay:=trunc(gross*m.entitlement,4);
 update public.binary_member_results set member_amount=member_pay,company_retention=gross-member_pay where cycle_id=cycle and member_id=m.member_id;
 if member_pay>0 then
 key:='binary:'||cycle::text||':'||m.member_id::text;
 insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
 values(m.member_id,'binary_pool_share',cycle,gross,m.entitlement,gross,member_pay,'MIO','phase1-binary-pool-v2',
 jsonb_build_object('completed_shares',m.completed_shares,'entitlement',m.entitlement,'member_amount',member_pay,'company_retention',gross-member_pay,'rounding','largest_remainder_4dp'),'posted',key) returning id into txn;
 update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
 if not found then raise exception 'Member wallet missing'; end if;
 insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)
 values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
 end if;
 end loop;
 if (select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=cycle)<>pool then raise exception 'Pool reconciliation failed'; end if;
 update public.binary_cycles set status='posted',total_completed_shares=share_count,gross_share_value=pool/share_count,closed_at=now() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'pool',pool,'shares',share_count,'rounding','largest_remainder_4dp'));
 return cycle;
end;
$$;
revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) from public,anon;
grant execute on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) to authenticated;



-- ===== schema/011_generation_row_assignment.sql =====
CREATE OR REPLACE FUNCTION private.credit_activation_bonuses(p_activation_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  act public.package_activations%rowtype;
  direct_sponsor uuid;
  beneficiary uuid;
  receiver_activation public.package_activations%rowtype;
  recipient record;
  gen_depth integer;
  gen_limit integer;
  gen1_rate numeric(10,8);
  gen2_rate numeric(10,8) := 0.05;
  stack_gen1 boolean := false;
  applied integer := 0;
  txn_id uuid;
  payout numeric(18,4);
  rate numeric(10,8);
  key text;
begin
  select * into act from public.package_activations where id=p_activation_id;
  if act.id is null or act.status<>'approved' then return 0; end if;
  select (config_value->>'direct_and_gen1_stack')::boolean,
         coalesce((config_value->>'gen2_plus_rate')::numeric,0.05)
    into stack_gen1,gen2_rate
    from public.system_config where config_key='GENERATION' and effective_to is null
    order by version desc limit 1;
  stack_gen1 := coalesce(stack_gen1,false);
  gen2_rate := coalesce(gen2_rate,0.05);
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=act.member_id;

  if direct_sponsor is not null and exists(select 1 from public.member_profiles where user_id=direct_sponsor and status='active')
     and private.current_package_code(direct_sponsor) is not null then
    payout := round(act.bv*act.direct_rate,4);
    if payout>0 then
      key := 'direct:' || act.id::text;
      insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,qualifying_base,rate,gross_amount,
        payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
      values(direct_sponsor,'direct',act.id,act.bv,act.direct_rate,payout,payout,'MIO','phase1-direct-v1',
        jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'rate',act.direct_rate,'calculation','BV x direct rate'),
        'posted',key) on conflict(idempotency_key) do nothing returning id into txn_id;
      if txn_id is not null then
        update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=direct_sponsor;
        insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
          values(direct_sponsor,payout,'bonus_credit',act.id,txn_id,'Direct bonus','bonus:'||txn_id::text);
        applied := applied+1;
      end if;
    end if;
  end if;

  -- Loop over a bounded sponsor chain. Depth is capped by the configured maximum.
  for recipient in
    with recursive uplines(user_id,sponsor_id,depth,path) as (
      select m.user_id,m.sponsor_id,1,array[m.user_id] from public.member_profiles m where m.user_id=act.member_id
      union all
      select parent.user_id,parent.sponsor_id,u.depth+1,u.path||parent.user_id
        from uplines u join public.member_profiles parent on parent.user_id=u.sponsor_id
        where u.sponsor_id is not null and u.depth<10 and not parent.user_id=any(u.path)
    )
    select u.sponsor_id as member_id,u.depth as generation
      from uplines u where u.sponsor_id is not null order by u.depth
  loop
    beneficiary := recipient.member_id;
    gen_depth := recipient.generation;
    if not exists(select 1 from public.member_profiles where user_id=beneficiary and status='active') then continue; end if;
    select a.* into receiver_activation
      from public.package_activations a join public.package_versions pv
        on pv.package_code=a.package_code and pv.version=a.package_version
      where a.member_id=beneficiary and a.status='approved'
      order by a.base_value desc,a.activated_at desc nulls last,a.requested_at desc limit 1;
    select pv.max_generations,pv.generation1_rate into gen_limit,gen1_rate
      from public.package_versions pv where pv.package_code=receiver_activation.package_code
        and pv.version=receiver_activation.package_version;
    if receiver_activation.id is null or gen_depth>gen_limit then continue; end if;
    if gen_depth=1 and not stack_gen1 then continue; end if;
    rate := case when gen_depth=1 then gen1_rate else gen2_rate end;
    payout := round(act.bv*rate,4);
    if payout<=0 then continue; end if;
    key := 'generation:'||act.id::text||':'||beneficiary::text||':'||gen_depth::text;
    insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,
      gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
    values(beneficiary,'generation',act.id,gen_depth,act.bv,rate,payout,payout,'MIO','phase1-generation-v1',
      jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'beneficiary_package',receiver_activation.package_code,
        'generation',gen_depth,'rate',rate,'direct_gen1_stack',stack_gen1), 'posted',key)
    on conflict(idempotency_key) do nothing returning id into txn_id;
    if txn_id is not null then
      update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=beneficiary;
      insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
        values(beneficiary,payout,'bonus_credit',act.id,txn_id,'Generation bonus','bonus:'||txn_id::text);
      applied := applied+1;
    end if;
  end loop;
  return applied;
end;
$function$;


-- ===== schema/012_referral_security_support.sql =====
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


-- ===== schema/013_company_controls.sql =====
alter table public.vendors add column commission_rate numeric(7,6) check(commission_rate between 0 and 1);
alter table public.order_items add column commission_rate_snapshot numeric(7,6);
insert into public.system_config(config_key,version,config_value,effective_from) values('DELIVERY',1,'{"fee_pkr":null,"policy":null}',now());
create function public.set_company_delivery(p_fee numeric,p_policy text) returns void language plpgsql security definer set search_path='' as $$
declare ver integer; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_fee is null or p_fee<0 or p_fee>100000 or p_fee<>round(p_fee,2) or length(trim(coalesce(p_policy,'')))<10 then raise exception 'Enter a valid shipping charge and delivery policy'; end if;
 perform pg_advisory_xact_lock(hashtextextended('delivery-config',0));
 select coalesce(max(version),0)+1 into ver from public.system_config where config_key='DELIVERY';
 update public.system_config set effective_to=now() where config_key='DELIVERY' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('DELIVERY',ver,jsonb_build_object('fee_pkr',p_fee,'policy',trim(p_policy)),now(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'DELIVERY_CONFIGURED','system_config',jsonb_build_object('version',ver,'fee_pkr',p_fee));
end $$;
create function public.set_vendor_commission(p_vendor_id uuid,p_rate numeric) returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_rate is null or p_rate<0 or p_rate>1 or p_rate<>round(p_rate,6) then raise exception 'Commission must be between 0 and 100 percent'; end if;
 update public.vendors set commission_rate=p_rate where id=p_vendor_id and status='active';
 if not found then raise exception 'Active seller not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_COMMISSION_SET','vendor',p_vendor_id,jsonb_build_object('rate',p_rate));
end $$;
alter function public.place_marketplace_order(jsonb,text,text,text,text,text) set schema private;
revoke all on function private.place_marketplace_order(jsonb,text,text,text,text,text) from public,anon,authenticated;
create function public.place_marketplace_order(p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare oid uuid; fee numeric; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended('order-policy:'||auth.uid()::text||':'||p_idempotency_key,0));
 select id into oid from public.orders where buyer_id=auth.uid() and idempotency_key=p_idempotency_key;
 if oid is not null then return oid; end if;
 select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
 if fee is null then raise exception 'Delivery charges are awaiting company configuration'; end if;
 if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid) join public.products p on p.id=x.product_id join public.vendors v on v.id=p.vendor_id where v.commission_rate is null) then raise exception 'A seller is awaiting contract configuration'; end if;
 oid:=private.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 update public.orders set delivery_fee_pkr=fee,total_pkr=subtotal_pkr+fee where id=oid;
 update public.order_items i set commission_rate_snapshot=v.commission_rate from public.vendors v where i.order_id=oid and i.vendor_id=v.id;
 return oid;
end $$;
revoke all on function public.set_company_delivery(numeric,text),public.set_vendor_commission(uuid,numeric),public.place_marketplace_order(jsonb,text,text,text,text,text) from public,anon;
grant execute on function public.set_company_delivery(numeric,text),public.set_vendor_commission(uuid,numeric),public.place_marketplace_order(jsonb,text,text,text,text,text) to authenticated;

-- An operations password can change only after a fresh verified portal request.
create table private.operator_password_permits(user_id uuid primary key,expires_at timestamptz not null);
revoke all on private.operator_password_permits from public,anon,authenticated;
create function public.authorize_operator_password_change() returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 insert into private.operator_password_permits values(auth.uid(),now()+interval '30 seconds') on conflict(user_id) do update set expires_at=excluded.expires_at;
end $$;
revoke all on function public.authorize_operator_password_change() from public,anon;
grant execute on function public.authorize_operator_password_change() to authenticated;
create function private.guard_operator_password() returns trigger language plpgsql security definer set search_path='' as $$begin
 if (to_jsonb(new)->>'encrypted_password') is distinct from (to_jsonb(old)->>'encrypted_password') and exists(select 1 from public.user_roles where user_id=new.id and role='admin') then
  delete from private.operator_password_permits where user_id=new.id and expires_at>now();
  if not found then raise exception 'Change this password from the verified workspace'; end if;
 end if; return new;
end $$;
revoke all on function private.guard_operator_password() from public,anon,authenticated;
create trigger guard_operator_password before update on auth.users for each row execute function private.guard_operator_password();


-- ===== schema/014_pending_account_and_setup.sql =====
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


-- ===== schema/015_explicit_ticket_permissions.sql =====
-- Hosted Supabase defaults can grant function execution directly to anon.
revoke all on function public.answer_recovery_ticket(uuid,text,boolean) from public,anon;
grant execute on function public.answer_recovery_ticket(uuid,text,boolean) to authenticated;


-- ===== schema/016_inventory_and_reports.sql =====
create function public.update_seller_inventory(p_product_id uuid,p_price numeric,p_stock integer)
returns void language plpgsql security definer set search_path='' as $$
declare product public.products%rowtype; begin
 if auth.uid() is null or not exists(select 1 from public.member_profiles where user_id=auth.uid() and status='active') then raise exception 'Active account required'; end if;
 if p_price is null or p_price<=0 or p_price>100000000 or p_price<>round(p_price,2) or p_stock is null or p_stock<0 or p_stock>1000000 then raise exception 'Invalid price or stock quantity'; end if;
 select p.* into product from public.products p join public.vendors v on v.id=p.vendor_id where p.id=p_product_id and v.owner_user_id=auth.uid() and v.status='active' for update of p;
 if product.id is null then raise exception 'Your active seller product was not found'; end if;
 update public.products set price_pkr=p_price,stock_quantity=p_stock,status=case when p_price<>product.price_pkr then 'pending'::public.product_status else status end,updated_at=now() where id=p_product_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'SELLER_INVENTORY_UPDATED','product',p_product_id,jsonb_build_object('price',product.price_pkr,'stock',product.stock_quantity),jsonb_build_object('price',p_price,'stock',p_stock));
end $$;
create function public.operations_report()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 return jsonb_build_object(
 'members',(select count(*) from public.member_profiles),
 'active_members',(select count(*) from public.member_profiles where status='active'),
 'approved_activations',(select count(*) from public.package_activations where status='approved'),
 'mio_wallet_total',(select coalesce(sum(balance),0) from public.mio_wallet_accounts),
 'mio_ledger_total',(select coalesce(sum(amount),0) from public.mio_ledger),
 'wallet_reconciles',(select coalesce(sum(balance),0) from public.mio_wallet_accounts)=(select coalesce(sum(amount),0) from public.mio_ledger),
 'bonuses_by_method',(select coalesce(jsonb_object_agg(method,total),'{}') from (select method,sum(payable_amount) total from public.bonus_transactions where status='posted' group by method) x),
 'binary_pool_total',(select coalesce(sum(pool_amount),0) from public.binary_cycles where status='posted'),
 'binary_member_payouts',(select coalesce(sum(member_amount),0) from public.binary_member_results),
 'binary_company_retention',(select coalesce(sum(company_retention),0) from public.binary_member_results),
 'orders',(select count(*) from public.orders),
 'confirmed_sales_pkr',(select coalesce(sum(total_pkr),0) from public.orders where payment_status='confirmed'),
 'open_recovery_tickets',(select count(*) from public.support_tickets where status<>'closed'));
end $$;
revoke all on function public.update_seller_inventory(uuid,numeric,integer),public.operations_report() from public,anon;
grant execute on function public.update_seller_inventory(uuid,numeric,integer),public.operations_report() to authenticated;


-- ===== schema/017_order_fulfillment.sql =====
create function public.advance_order_status(p_order_id uuid,p_status public.order_status)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; states public.order_status[]:=array['placed','confirmed','processing','shipped','delivered']::public.order_status[]; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null then raise exception 'Order not found'; end if;
 if o.status=p_status then return; end if;
 if array_position(states,p_status) is null or array_position(states,o.status) is null or array_position(states,p_status)<>array_position(states,o.status)+1 then raise exception 'Order must advance one fulfillment stage at a time'; end if;
 update public.orders set status=p_status,updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'ORDER_STATUS_CHANGED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status',p_status));
end $$;
create function public.cancel_unpaid_order(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; item record; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null or (o.buyer_id<>auth.uid() and not private.has_role('admin')) then raise exception 'Order not found'; end if;
 if o.status='cancelled' then return; end if;
 if o.payment_status<>'unconfirmed' or o.status not in('placed','confirmed','processing') or (not private.has_role('admin') and o.status<>'placed') then raise exception 'This order cannot be cancelled here; contact the company'; end if;
 for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
  update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
 end loop;
 update public.orders set status='cancelled',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'UNPAID_ORDER_CANCELLED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status','cancelled','inventory_restored',true));
end $$;
revoke all on function public.advance_order_status(uuid,public.order_status),public.cancel_unpaid_order(uuid) from public,anon;
grant execute on function public.advance_order_status(uuid,public.order_status),public.cancel_unpaid_order(uuid) to authenticated;


-- ===== schema/018_verified_offline_premium_purchase.sql =====
-- Owner-approved separate MIO purchase + Premium activation, not an ordinary transfer.
alter table public.mio_ledger drop constraint mio_ledger_action_check;
alter table public.mio_ledger add constraint mio_ledger_action_check check(action in('admin_mint','admin_burn','transfer_in','transfer_out','package_activation','bonus_credit','purchase_in','purchase_out'));
alter table public.mio_ledger drop constraint mio_ledger_check;
alter table public.mio_ledger add constraint mio_ledger_check check((action in('transfer_in','transfer_out','purchase_in','purchase_out') and counterparty_id is not null and transfer_id is not null) or (action not in('transfer_in','transfer_out','purchase_in','purchase_out') and counterparty_id is null and transfer_id is null));
alter table public.mio_ledger drop constraint mio_ledger_amount_check;
alter table public.mio_ledger add constraint mio_ledger_amount_check check((action in('admin_mint','transfer_in','bonus_credit','purchase_in') and amount>0) or (action in('admin_burn','transfer_out','package_activation','purchase_out') and amount<0));
create table public.premium_purchase_requests(
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.member_profiles(user_id),package_version integer not null,
 mio_amount numeric(20,4) not null check(mio_amount>0),usd_to_pkr_rate numeric(14,6) not null check(usd_to_pkr_rate>0),expected_pkr numeric(14,2) not null check(expected_pkr>0),
 payment_reference text not null unique,payment_details text not null,status text not null default 'pending' check(status in('pending','approved','rejected')),
 activation_id uuid references public.package_activations(id),reviewed_by uuid references auth.users(id),review_note text,created_at timestamptz not null default now(),reviewed_at timestamptz,
 idempotency_key text not null unique);
alter table public.premium_purchase_requests enable row level security;
create policy "buyer or operations reads Premium purchase" on public.premium_purchase_requests for select to authenticated using(member_id=auth.uid() or private.has_role('admin'));
grant select on public.premium_purchase_requests to authenticated;
revoke insert,update,delete on public.premium_purchase_requests from anon,authenticated;
create function public.request_offline_premium_purchase(p_reference text,p_details text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.package_versions%rowtype; rate numeric; rid uuid; begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status='active') then raise exception 'Active member account required'; end if;
 if private.has_role('admin') then raise exception 'Use your company MIO wallet to activate your own package'; end if;
 if length(trim(coalesce(p_reference,'')))<8 or length(p_reference)>200 or length(trim(coalesce(p_details,'')))<20 or length(p_details)>2000 or length(coalesce(p_idempotency_key,''))<12 then raise exception 'Enter the genuine payment provider, reference and payment details'; end if;
 perform pg_advisory_xact_lock(hashtextextended('premium-purchase:'||uid::text,0));
 select id into rid from public.premium_purchase_requests where member_id=uid and idempotency_key=uid::text||':'||p_idempotency_key;
 if rid is not null then return rid; end if;
 if private.current_package_code(uid)='PREMIUM' then raise exception 'Premium is already active'; end if;
 if exists(select 1 from public.premium_purchase_requests where member_id=uid and status='pending') then raise exception 'You already have a pending Premium purchase'; end if;
 select * into p from public.package_versions where package_code='PREMIUM' and is_active and effective_from<=now() and (effective_to is null or effective_to>now()) order by version desc limit 1;
 if p.package_code is null then raise exception 'Premium is unavailable'; end if;
 select (config_value->>'usd_to_pkr_rate')::numeric into rate from public.system_config where config_key='CURRENCY' and effective_to is null order by version desc limit 1;
 if rate is null then raise exception 'The company must configure the purchase conversion rate first'; end if;
 if not exists(select 1 from public.system_config where config_key='OFFLINE_PAYMENT' and effective_to is null and length(config_value->>'instructions')>=20) then raise exception 'Company payment instructions are not configured'; end if;
 insert into public.premium_purchase_requests(member_id,package_version,mio_amount,usd_to_pkr_rate,expected_pkr,payment_reference,payment_details,idempotency_key)
 values(uid,p.version,p.payable_price,rate,round(p.payable_price*rate,2),upper(trim(p_reference)),trim(p_details),uid::text||':'||p_idempotency_key) returning id into rid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(uid,'OFFLINE_PREMIUM_REQUESTED','premium_purchase',rid);
 return rid;
end $$;
create function public.review_offline_premium_purchase(p_request_id uuid,p_approve boolean,p_verified_pkr numeric,p_note text)
returns uuid language plpgsql security definer set search_path='' as $$
declare owner uuid:=auth.uid(); r public.premium_purchase_requests%rowtype; p public.package_versions%rowtype; aid uuid:=gen_random_uuid(); lock_uid uuid; request_key text; new_balance numeric;
begin
 if owner is null or not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if p_approve is null or length(trim(coalesce(p_note,'')))<20 or length(p_note)>2000 then raise exception 'Record a verification or rejection note of at least 20 characters'; end if;
 select * into r from public.premium_purchase_requests where id=p_request_id for update;
 if r.id is null then raise exception 'Purchase request not found'; end if;
 if r.status='approved' then return r.activation_id; end if;
 if r.status<>'pending' then raise exception 'Purchase request is already closed'; end if;
 if not p_approve then
  update public.premium_purchase_requests set status='rejected',reviewed_by=owner,review_note=trim(p_note),reviewed_at=now() where id=r.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(owner,'OFFLINE_PREMIUM_REJECTED','premium_purchase',r.id,jsonb_build_object('note',trim(p_note)));
  return null;
 end if;
 if p_verified_pkr is null or p_verified_pkr<>r.expected_pkr then raise exception 'Verified payment must match the saved purchase amount'; end if;
 if r.member_id=owner or not exists(select 1 from public.member_profiles where user_id=r.member_id and status='active') then raise exception 'Active buyer account required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('package-member:'||r.member_id::text,0));
 if private.current_package_code(r.member_id)='PREMIUM' then raise exception 'Premium is already active; resolve the duplicate payment with the buyer'; end if;
 select * into p from public.package_versions where package_code='PREMIUM' and version=r.package_version;
 if p.package_code is null or p.payable_price<>r.mio_amount then raise exception 'Saved package configuration not found'; end if;
 for lock_uid in select member_id from public.mio_wallet_accounts where member_id in(owner,r.member_id) order by member_id for update loop null; end loop;
 update public.mio_wallet_accounts set balance=balance-r.mio_amount,updated_at=now() where member_id=owner and balance>=r.mio_amount returning balance into new_balance;
 if new_balance is null then raise exception 'Company wallet needs sufficient MIO stock before approval'; end if;
 request_key:='offline-premium:'||r.id::text;
 update public.mio_wallet_accounts set balance=balance+r.mio_amount,updated_at=now() where member_id=r.member_id;
 insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,reason,idempotency_key) values
 (owner,-r.mio_amount,'purchase_out',r.member_id,r.id,'Verified Premium purchase',request_key||':stock'),
 (r.member_id,r.mio_amount,'purchase_in',owner,r.id,'Verified Premium purchase',request_key||':purchase');
 update public.mio_wallet_accounts set balance=balance-r.mio_amount,updated_at=now() where member_id=r.member_id;
 insert into public.package_activations(id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
 values(aid,r.member_id,p.package_code,p.version,'MIO_POINTS',r.id::text,'MIO',r.mio_amount,1,p.base_value,p.company_fee,p.payable_price,p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,'approved',now(),owner,request_key);
 insert into public.mio_ledger(member_id,amount,action,activation_id,reason,idempotency_key) values(r.member_id,-r.mio_amount,'package_activation',aid,'Offline purchase activated atomically',request_key||':activation');
 insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key) values(r.member_id,'PPV',p.ppv,aid,'credit',request_key||':ppv');
 perform private.credit_activation_bonuses(aid);
 update public.premium_purchase_requests set status='approved',activation_id=aid,reviewed_by=owner,review_note=trim(p_note),reviewed_at=now() where id=r.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(owner,'OFFLINE_PREMIUM_APPROVED','premium_purchase',r.id,jsonb_build_object('buyer_id',r.member_id,'activation_id',aid,'mio',r.mio_amount,'verified_pkr',p_verified_pkr,'conversion_rate',r.usd_to_pkr_rate,'note',trim(p_note)));
 return aid;
end $$;
revoke all on function public.request_offline_premium_purchase(text,text,text),public.review_offline_premium_purchase(uuid,boolean,numeric,text) from public,anon;
grant execute on function public.request_offline_premium_purchase(text,text,text),public.review_offline_premium_purchase(uuid,boolean,numeric,text) to authenticated;
insert into public.system_config(config_key,version,config_value,effective_from) values('OFFLINE_PAYMENT',1,'{"instructions":null}',now());
create function public.set_offline_payment_instructions(p_instructions text) returns void language plpgsql security definer set search_path='' as $$
declare ver integer; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if length(trim(coalesce(p_instructions,'')))<20 or length(p_instructions)>4000 then raise exception 'Provide payment instructions of 20–4000 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-payment-config',0));
 select coalesce(max(version),0)+1 into ver from public.system_config where config_key='OFFLINE_PAYMENT';
 update public.system_config set effective_to=now() where config_key='OFFLINE_PAYMENT' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('OFFLINE_PAYMENT',ver,jsonb_build_object('instructions',trim(p_instructions)),now(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'OFFLINE_PAYMENT_INSTRUCTIONS_SET','system_config',jsonb_build_object('version',ver));
end $$;
revoke all on function public.set_offline_payment_instructions(text) from public,anon;
grant execute on function public.set_offline_payment_instructions(text) to authenticated;


-- ===== schema/20261002095837_network_income_method.sql =====
alter type public.bonus_method add value if not exists 'single_line';


-- ===== schema/20261002095848_network_vendor_workflows.sql =====
CREATE OR REPLACE FUNCTION private.mio_transfer(p_recipient_id uuid, p_amount numeric, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 or p_amount <> round(p_amount,4) then raise exception 'Invalid MIO amount'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 or length(p_idempotency_key) > 100 then raise exception 'Invalid idempotency key'; end if;

  perform pg_advisory_xact_lock(hashtextextended('mio-request:'||sender_id::text||':'||p_idempotency_key,0));
  if not exists(select 1 from public.member_profiles where user_id=sender_id and status='active') or not exists(select 1 from public.member_profiles where user_id=p_recipient_id and status='active') then raise exception 'Both accounts must be active'; end if;
  select transfer_id into existing_transfer from public.mio_ledger
    where idempotency_key = sender_id::text || ':' || p_idempotency_key || ':out';
  if existing_transfer is not null then return existing_transfer; end if;

  select private.has_role('admin') into sender_admin;
  select exists(select 1 from public.user_roles r where r.user_id=p_recipient_id and r.role='admin')
    into recipient_admin;
  sender_premium := coalesce(private.current_package_code(sender_id) = 'PREMIUM',false);
  recipient_premium := coalesce(private.current_package_code(p_recipient_id) = 'PREMIUM',false);
  -- Company may send to every active member; ordinary incoming rules remain.
  if not sender_admin then
    if recipient_admin and not sender_premium then
      raise exception 'Only Premium members can send to company';
    elsif not recipient_admin and not (sender_premium or recipient_premium) then
      raise exception 'At least one member in a MIO transfer must hold the Premium package';
    end if;
  end if;

  -- Lock in a deterministic order to prevent double-spending and deadlocks.
  for locked_user in
    select member_id from public.mio_wallet_accounts
    where member_id in (sender_id, p_recipient_id) order by member_id
    for update
  loop null; end loop;
  select balance into wallet_balance from public.mio_wallet_accounts where member_id = sender_id;
  if wallet_balance is null or not exists(select 1 from public.mio_wallet_accounts where member_id=p_recipient_id) then raise exception 'Wallet not initialized'; end if;
  if wallet_balance < p_amount then raise exception 'Insufficient MIO balance'; end if;

  update public.mio_wallet_accounts set balance = balance - p_amount, updated_at = now() where member_id = sender_id;
  update public.mio_wallet_accounts set balance = balance + p_amount, updated_at = now() where member_id = p_recipient_id;
  insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,idempotency_key)
    values (sender_id,-p_amount,'transfer_out',p_recipient_id,transfer_key,sender_id::text || ':' || p_idempotency_key || ':out'),
           (p_recipient_id,p_amount,'transfer_in',sender_id,transfer_key,sender_id::text || ':' || p_idempotency_key || ':in');
  return transfer_key;
end;
$function$;

-- The company is outside the member binary tree. This registry is private.
create table private.network_foundation(singleton boolean primary key default true check(singleton),company_id uuid not null unique references public.member_profiles(user_id),founder_id uuid not null unique references public.member_profiles(user_id),check(company_id<>founder_id));
revoke all on private.network_foundation from public,anon,authenticated;
do $$declare c uuid; f uuid; begin
 select m.user_id into c from public.member_profiles m join public.user_roles r on r.user_id=m.user_id and r.role='admin' where m.full_name='Market is Online Operations';
 select user_id into f from public.member_profiles where full_name='Abdul Rehman Abbasi' and sponsor_id=c;
 if c is not null and f is not null then
  if exists(select 1 from public.binary_placements where member_id=c or (member_id=f and parent_id is not null)) then raise exception 'Existing founder placement requires review'; end if;
  if exists(select 1 from public.member_profiles where sponsor_id=c and user_id<>f) then raise exception 'Company has another direct member'; end if;
  insert into private.network_foundation values(true,c,f);
  insert into public.binary_placements(member_id,parent_id,side,placed_by) values(f,null,null,c) on conflict(member_id) do nothing;
 end if;
end $$;

create function private.guard_foundation_profile() returns trigger language plpgsql security definer set search_path='' as $$begin
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 if exists(select 1 from private.network_foundation where company_id=new.sponsor_id and founder_id<>new.user_id) then raise exception 'Company has one founder only. Use Abdul Rehman or a team referral'; end if;
 if tg_op='UPDATE' and exists(select 1 from private.network_foundation where (founder_id=new.user_id and company_id is distinct from new.sponsor_id) or (company_id=new.user_id and new.sponsor_id is not null)) then raise exception 'Company and founder relationships are permanent'; end if;
 return new;
end $$;
create trigger foundation_profile_guard before insert or update of sponsor_id on public.member_profiles for each row execute function private.guard_foundation_profile();
create function private.guard_company_binary() returns trigger language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.user_roles where user_id in(new.member_id,new.parent_id) and role='admin') then raise exception 'Company has no left/right binary placement'; end if;
 if exists(select 1 from private.network_foundation where founder_id=new.member_id) and new.parent_id is not null then raise exception 'Founder is the member binary root'; end if;
 return new;
end $$;
create trigger company_binary_guard before insert or update on public.binary_placements for each row execute function private.guard_company_binary();

-- Side is encoded in the referral code, then validated before sponsor signup.
create function private.normalize_side_referral() returns trigger language plpgsql security definer set search_path='' as $$
declare ref text:=upper(trim(coalesce(new.raw_user_meta_data->>'referral_code',''))); begin
 if ref ~ '-[LR]$' then
  new.raw_user_meta_data:=new.raw_user_meta_data||jsonb_build_object('referral_code',left(ref,length(ref)-2),'referral_side',case right(ref,1) when 'L' then 'LEFT' else 'RIGHT' end);
 end if;
 return new;
end $$;
create trigger normalize_side_referral before insert on auth.users for each row execute function private.normalize_side_referral();
create function private.place_outermost(p_member uuid,p_sponsor uuid,p_side text) returns void language plpgsql security definer set search_path='' as $$
declare parent uuid:=p_sponsor; child uuid; hops integer:=0; begin
 if p_side is null or p_side not in('LEFT','RIGHT') then raise exception 'Choose LEFT or RIGHT'; end if;
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 if exists(select 1 from public.user_roles where user_id=p_sponsor and role='admin') then raise exception 'Company has no left/right links. Use founder referral'; end if;
 if exists(select 1 from public.binary_placements where member_id=p_member) then return; end if;
 if not exists(select 1 from public.binary_placements where member_id=parent) then raise exception 'Sponsor binary position must be set first'; end if;
 loop
  select member_id into child from public.binary_placements where parent_id=parent and side=p_side;
  exit when child is null;
  parent:=child; hops:=hops+1;
  if parent=p_member or hops>10000 then raise exception 'Invalid or excessively deep binary path'; end if;
 end loop;
 insert into public.binary_placements(member_id,parent_id,side,placed_by) values(p_member,parent,p_side,p_sponsor);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(p_sponsor,'REFERRAL_BINARY_PLACED','binary_placement',p_member,jsonb_build_object('sponsor',p_sponsor,'parent',parent,'side',p_side));
end $$;
create function private.place_signup_binary() returns trigger language plpgsql security definer set search_path='' as $$declare side text; begin
 select raw_user_meta_data->>'referral_side' into side from auth.users where id=new.user_id;
 if new.status='active' and new.sponsor_id is not null and side is not null then perform private.place_outermost(new.user_id,new.sponsor_id,upper(side)); end if;
 return new;
end $$;
create trigger signup_binary_placement after insert on public.member_profiles for each row execute function private.place_signup_binary();

create function public.lookup_transfer_recipient(p_code text) returns table(member_code text,full_name text) language plpgsql stable security definer set search_path='' as $$begin
 if auth.uid() is null or not exists(select 1 from public.member_profiles where user_id=auth.uid() and status='active') then raise exception 'Active account required'; end if;
 return query select m.member_code,m.full_name from public.member_profiles m where (upper(m.member_code)=upper(trim(p_code)) or upper(m.referral_code)=upper(trim(p_code))) and m.status='active' and m.user_id<>auth.uid();
end $$;
create function public.lookup_side_referral(p_code text) returns table(member_code text,full_name text,placement_side text) language sql stable security definer set search_path='' as $$
 select m.member_code,m.full_name,case right(upper(trim(p_code)),2) when '-L' then 'LEFT' when '-R' then 'RIGHT' else null end
 from public.member_profiles m where (upper(m.referral_code)=regexp_replace(upper(trim(p_code)),'-[LR]$','') or upper(m.member_code)=regexp_replace(upper(trim(p_code)),'-[LR]$','')) and m.status='active' and not exists(select 1 from public.user_roles r where r.user_id=m.user_id and r.role='admin');
$$;

-- Single-line follows placement parents, with exact rational cumulative rounding.
create function private.credit_single_line(p_activation uuid) returns void language plpgsql security definer set search_path='' as $$
declare a public.package_activations%rowtype; r record; lim integer; pkg text; amount numeric; tx uuid; begin
 select * into a from public.package_activations where id=p_activation and status='approved';
 if a.id is null then return; end if;
 for r in with recursive up(member_id,depth,path) as (
  select b.parent_id,1,array[a.member_id,b.parent_id] from public.binary_placements b where b.member_id=a.member_id and b.parent_id is not null
  union all select b.parent_id,u.depth+1,u.path||b.parent_id from up u join public.binary_placements b on b.member_id=u.member_id where u.depth<30 and b.parent_id is not null and not b.parent_id=any(u.path)
 ) select * from up order by depth loop
  pkg:=private.current_package_code(r.member_id);
  lim:=case pkg when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 when 'PREMIUM' then 30 else 0 end;
  if r.depth>lim or not exists(select 1 from public.member_profiles where user_id=r.member_id and status='active') then continue; end if;
  amount:=round(a.bv*r.depth/300,4)-round(a.bv*(r.depth-1)/300,4);
  if amount<=0 then continue; end if;
  tx:=null;
  insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
  values(r.member_id,'single_line',a.id,r.depth,a.bv,1::numeric/300,a.bv/300,amount,'MIO','single-line-placement-v1',jsonb_build_object('rate_numerator',1,'rate_denominator',300,'placement_level',r.depth,'package',pkg,'limit',lim,'rounding','cumulative difference at 4 decimals'),'posted','single:'||a.id||':'||r.member_id) on conflict(idempotency_key) do nothing returning id into tx;
  if tx is not null then
   update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=r.member_id;
   insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key) values(r.member_id,amount,'bonus_credit',a.id,tx,'Single line income','bonus:'||tx);
  end if;
 end loop;
end $$;
create function private.activation_single_line() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' then perform private.credit_single_line(new.id); end if; return new;
end $$;
create trigger activation_single_line after insert on public.package_activations for each row execute function private.activation_single_line();

create function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); root uuid; is_company boolean; allowed boolean; result jsonb; begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status='active') then raise exception 'Active account required'; end if;
 if p_kind not in('generation','binary','pool','single_line','vendor') or p_depth not between 1 and 6 then raise exception 'Invalid tree view'; end if;
 is_company:=private.has_role('admin'); root:=uid;
 if is_company and p_kind in('binary','pool','single_line') then select founder_id into root from private.network_foundation where company_id=uid; end if;
 if nullif(trim(p_root_code),'') is not null then
  select user_id into root from public.member_profiles where member_code=upper(trim(p_root_code));
  with recursive team(id,path) as(select uid,array[uid] union all select m.user_id,t.path||m.user_id from team t join public.member_profiles m on m.sponsor_id=t.id where not m.user_id=any(t.path)) select exists(select 1 from team where id=root) into allowed;
  if not is_company and not allowed then
   with recursive team(id,path) as(select uid,array[uid] union all select b.member_id,t.path||b.member_id from team t join public.binary_placements b on b.parent_id=t.id where not b.member_id=any(t.path)) select exists(select 1 from team where id=root) into allowed;
   if not allowed then raise exception 'Your network only'; end if;
  end if;
 end if;
 if root is null then return jsonb_build_object('nodes','[]'::jsonb); end if;
 if p_kind='vendor' then
  return jsonb_build_object('nodes',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'parent_id',root,'full_name',v.business_name,'member_code',m.member_code,'depth',1,'commission_rate',v.commission_rate,'status',v.status)) from public.vendors v join public.member_profiles m on m.user_id=v.owner_user_id where m.sponsor_id=root),'[]'::jsonb));
 end if;
 with recursive tree(id,parent_id,side,depth,path) as (
  select root,null::uuid,null::text,0,array[root]
  union all select m.user_id, t.id,case when p_kind='generation' then null else b.side end,t.depth+1,t.path||m.user_id from tree t join public.member_profiles m on
   (p_kind='generation' and m.sponsor_id=t.id) or (p_kind<>'generation' and exists(select 1 from public.binary_placements x where x.member_id=m.user_id and x.parent_id=t.id))
   left join public.binary_placements b on b.member_id=m.user_id where t.depth<p_depth and not m.user_id=any(t.path)
 ), bounded as(select * from tree order by depth,id limit 501)
 select jsonb_build_object('truncated',count(*)>500,'nodes',coalesce(jsonb_agg(jsonb_build_object('id',t.id,'parent_id',t.parent_id,'side',t.side,'depth',t.depth,'member_code',m.member_code,'full_name',m.full_name,'status',m.status,'package',private.current_package_code(t.id),
 'bp',coalesce((select bp from public.package_activations a where a.member_id=t.id and a.status='approved' order by base_value desc,activated_at desc limit 1),0),
 'left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT'),0)-coalesce((select sum(consumed_left) from public.binary_member_results where member_id=t.id),0),
 'right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT'),0)-coalesce((select sum(consumed_right) from public.binary_member_results where member_id=t.id),0)) order by t.depth,t.side,t.id) filter(where t.id in(select id from bounded limit 500)),'[]'::jsonb)) into result from bounded t join public.member_profiles m on m.user_id=t.id;
 return result;
end $$;
-- Pending onboarding uses the same side code and placement policy.
alter function public.complete_referral_join(text,text,text,boolean) set schema private;
revoke all on function private.complete_referral_join(text,text,text,boolean) from public,anon,authenticated;
create function public.complete_referral_join(p_full_name text,p_phone text,p_referral_code text,p_consent boolean) returns void language plpgsql security definer set search_path='' as $$declare ref text:=upper(trim(p_referral_code)); side text; sponsor uuid; begin
 if ref ~ '-[LR]$' then side:=case right(ref,1) when 'L' then 'LEFT' else 'RIGHT' end;ref:=left(ref,length(ref)-2); end if;
 perform private.complete_referral_join(p_full_name,p_phone,ref,p_consent);
 select sponsor_id into sponsor from public.member_profiles where user_id=auth.uid();
 if side is not null then perform private.place_outermost(auth.uid(),sponsor,side); end if;
end $$;

alter function public.admin_review_vendor_application(uuid,boolean) set schema private;
revoke all on function private.admin_review_vendor_application(uuid,boolean) from public,anon,authenticated;
create function public.admin_review_vendor_application(p_application_id uuid,p_approve boolean,p_commission_rate numeric default null) returns uuid language plpgsql security definer set search_path='' as $$declare v uuid; begin
 if p_approve and (p_commission_rate is null or p_commission_rate<0 or p_commission_rate>1 or p_commission_rate<>round(p_commission_rate,6)) then raise exception 'Set this vendor commission at approval'; end if;
 v:=private.admin_review_vendor_application(p_application_id,p_approve);
 if p_approve then perform public.set_vendor_commission(v,p_commission_rate); end if;
 return v;
end $$;

alter table public.products add column ppv_per_unit numeric(18,4) check(ppv_per_unit>=0 and ppv_per_unit<=1000000);
alter table public.order_items add column ppv_per_unit_snapshot numeric(18,4);
create function private.guard_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 if (tg_op='INSERT' and new.ppv_per_unit is not null) or (tg_op='UPDATE' and new.ppv_per_unit is distinct from old.ppv_per_unit) then
  if not private.has_role('admin') then raise exception 'Only company review assigns product PPV'; end if;
 end if;
 return new;
end $$;
create trigger guard_product_ppv before insert or update on public.products for each row execute function private.guard_product_ppv();
alter function public.admin_review_product(uuid,boolean) set schema private;
revoke all on function private.admin_review_product(uuid,boolean) from public,anon,authenticated;
create function public.admin_review_product(p_product_id uuid,p_approve boolean,p_ppv numeric default null) returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_approve and (p_ppv is null or p_ppv<0 or p_ppv>1000000 or p_ppv<>round(p_ppv,4)) then raise exception 'Assign PPV to this product before approval'; end if;
 perform private.admin_review_product(p_product_id,p_approve);
 if p_approve then update public.products set ppv_per_unit=p_ppv where id=p_product_id; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_PPV_REVIEWED','product',p_product_id,jsonb_build_object('approved',p_approve,'ppv_per_unit',p_ppv));
end $$;
create function private.snapshot_item_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 select ppv_per_unit into new.ppv_per_unit_snapshot from public.products where id=new.product_id;
 if new.ppv_per_unit_snapshot is null then raise exception 'Product PPV is awaiting company review'; end if;
 return new;
end $$;
create trigger snapshot_item_ppv before insert on public.order_items for each row execute function private.snapshot_item_ppv();
-- Existing approved listings require PPV review; existing orders retain history.
update public.products set status='pending' where status='approved' and ppv_per_unit is null;

create or replace function public.admin_confirm_order_payment(p_order_id uuid)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  order_row public.orders%rowtype;
  ppv_value numeric(18,4);
  current_ppv numeric(18,4);
  activated integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select * into order_row from public.orders where id=p_order_id for update;
  if order_row.id is null then raise exception 'Order not found'; end if;
  if order_row.payment_status='confirmed' then return order_row.ppv_generated; end if;
  if order_row.payment_status<>'unconfirmed' or order_row.status in ('cancelled','returned') then
    raise exception 'Order is not eligible for payment confirmation';
  end if;
  select coalesce(sum(coalesce(ppv_per_unit_snapshot,unit_price_pkr/order_row.usd_to_pkr_rate)*quantity),0) into ppv_value from public.order_items where order_id=order_row.id;
  ppv_value:=round(ppv_value,4);
  update public.orders set payment_status='confirmed',ppv_generated=ppv_value,updated_at=now() where id=order_row.id;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
    values(order_row.buyer_id,'PPV',ppv_value,order_row.id,'credit','order:' || order_row.id::text || ':ppv')
    on conflict(idempotency_key) do nothing;
  select coalesce(sum(amount),0) into current_ppv from public.point_ledger
    where member_id=order_row.buyer_id and point_type='PPV';
  activated := private.activate_next_ppv_package(order_row.buyer_id,order_row.id,current_ppv);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ORDER_PAYMENT_CONFIRMED','order',order_row.id,
      jsonb_build_object('buyer_id',order_row.buyer_id,'ppv_generated',ppv_value,'cumulative_ppv',current_ppv,'auto_activations',activated));
  return ppv_value;
end;
$$;

-- Seller proceeds are PKR and remain separate from MIO member earnings.
create table public.vendor_income_ledger(id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.vendors(id),order_item_id uuid unique references public.order_items(id),gross_pkr numeric(18,2) not null,commission_pkr numeric(18,2) not null,net_pkr numeric(18,2) not null check(net_pkr=gross_pkr-commission_pkr),created_at timestamptz not null default now());
create index vendor_income_vendor_idx on public.vendor_income_ledger(vendor_id,created_at desc);
alter table public.vendor_income_ledger enable row level security;
create policy vendor_income_read on public.vendor_income_ledger for select to authenticated using(private.has_role('admin') or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=auth.uid()));
grant select on public.vendor_income_ledger to authenticated;
revoke insert,update,delete on public.vendor_income_ledger from anon,authenticated;
create function private.post_vendor_sale() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr)
  select i.vendor_id,i.id,i.line_total_pkr,round(i.line_total_pkr*i.commission_rate_snapshot,2),i.line_total_pkr-round(i.line_total_pkr*i.commission_rate_snapshot,2) from public.order_items i where i.order_id=new.id on conflict(order_item_id) do nothing;
 end if;
 return new;
end $$;
create trigger post_vendor_sale after update of payment_status on public.orders for each row execute function private.post_vendor_sale();
create table public.vendor_withdrawals(id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.vendors(id),amount_pkr numeric(18,2) not null check(amount_pkr>0),bank_name text not null,account_name text not null,account_number text not null,status text not null default 'pending' check(status in('pending','approved','paid','rejected')),idempotency_key text not null,review_note text,reviewed_by uuid references auth.users(id),created_at timestamptz not null default now(),reviewed_at timestamptz,unique(vendor_id,idempotency_key));
create index vendor_withdrawals_status_idx on public.vendor_withdrawals(vendor_id,status);
alter table public.vendor_withdrawals enable row level security;
create policy vendor_withdrawal_read on public.vendor_withdrawals for select to authenticated using(private.has_role('admin') or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=auth.uid()));
grant select on public.vendor_withdrawals to authenticated;
revoke insert,update,delete on public.vendor_withdrawals from anon,authenticated;
create function public.request_vendor_withdrawal(p_amount numeric,p_bank text,p_account_name text,p_account_number text,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare vid uuid; available numeric; wid uuid; begin
 select id into vid from public.vendors where owner_user_id=auth.uid() and status='active' for update;
 if vid is null then raise exception 'Active seller required'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>1000000000 then raise exception 'Invalid withdrawal amount'; end if;
 if length(trim(coalesce(p_bank,''))) not between 2 and 100 or length(trim(coalesce(p_account_name,''))) not between 2 and 150 or length(trim(coalesce(p_account_number,''))) not between 5 and 100 or length(coalesce(p_idempotency_key,'')) not between 12 and 100 then raise exception 'Complete your bank details'; end if;
 select id into wid from public.vendor_withdrawals where vendor_id=vid and idempotency_key=p_idempotency_key;
 if wid is not null then return wid; end if;
 select coalesce((select sum(net_pkr) from public.vendor_income_ledger where vendor_id=vid),0)-coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=vid and status in('pending','approved','paid')),0) into available;
 if p_amount>available then raise exception 'Insufficient available seller income'; end if;
 insert into public.vendor_withdrawals(vendor_id,amount_pkr,bank_name,account_name,account_number,idempotency_key) values(vid,p_amount,trim(p_bank),trim(p_account_name),trim(p_account_number),p_idempotency_key) returning id into wid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_WITHDRAWAL_REQUESTED','vendor_withdrawal',wid,jsonb_build_object('vendor_id',vid,'amount_pkr',p_amount));
 return wid;
end $$;
create function public.review_vendor_withdrawal(p_request_id uuid,p_status text,p_note text) returns void language plpgsql security definer set search_path='' as $$declare w public.vendor_withdrawals%rowtype; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 select * into w from public.vendor_withdrawals where id=p_request_id for update;
 if w.id is null then raise exception 'Withdrawal not found'; end if;
 if p_status not in('approved','paid','rejected') or length(trim(coalesce(p_note,'')))<10 or length(p_note)>2000 then raise exception 'Choose a valid decision and record payment reference or reason'; end if;
 if w.status=p_status then return; end if;
 if not ((w.status='pending' and p_status in('approved','rejected')) or (w.status='approved' and p_status in('paid','rejected'))) then raise exception 'Invalid withdrawal transition'; end if;
 update public.vendor_withdrawals set status=p_status,review_note=trim(p_note),reviewed_by=auth.uid(),reviewed_at=now() where id=w.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'VENDOR_WITHDRAWAL_REVIEWED','vendor_withdrawal',w.id,jsonb_build_object('status',w.status),jsonb_build_object('status',p_status,'note',trim(p_note),'amount',w.amount_pkr));
end $$;
create function public.my_vendor_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$declare vid uuid; begin
 select id into vid from public.vendors where owner_user_id=auth.uid() and status='active';
 if vid is null then return null; end if;
 return jsonb_build_object('sales_pkr',coalesce((select sum(gross_pkr) from public.vendor_income_ledger where vendor_id=vid),0),'commission_pkr',coalesce((select sum(commission_pkr) from public.vendor_income_ledger where vendor_id=vid),0),'income_pkr',coalesce((select sum(net_pkr) from public.vendor_income_ledger where vendor_id=vid),0),'reserved_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=vid and status in('pending','approved')),0),'paid_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=vid and status='paid'),0));
end $$;
-- No company left/right volume; incentives retain their existing ledger sources.
create function public.company_network_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 return jsonb_build_object('founder',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.founder_id where n.company_id=auth.uid()),'binary_retention_mio',coalesce((select sum(company_retention) from public.binary_member_results),0),'seller_commission_pkr',coalesce((select sum(commission_pkr) from public.vendor_income_ledger),0),'package_fees_mio',coalesce((select sum(company_fee) from public.package_activations where status='approved'),0));
end $$;

revoke all on function private.guard_foundation_profile(),private.guard_company_binary(),private.normalize_side_referral(),private.place_outermost(uuid,uuid,text),private.place_signup_binary(),private.credit_single_line(uuid),private.activation_single_line(),private.guard_product_ppv(),private.snapshot_item_ppv(),private.post_vendor_sale() from public,anon,authenticated;
revoke all on function public.lookup_transfer_recipient(text),public.lookup_side_referral(text),public.complete_referral_join(text,text,text,boolean),public.my_network(text,text,integer),public.admin_review_vendor_application(uuid,boolean,numeric),public.admin_review_product(uuid,boolean,numeric),public.request_vendor_withdrawal(numeric,text,text,text,text),public.review_vendor_withdrawal(uuid,text,text),public.my_vendor_summary(),public.company_network_summary() from public,anon;
grant execute on function public.lookup_transfer_recipient(text),public.complete_referral_join(text,text,text,boolean),public.my_network(text,text,integer),public.admin_review_vendor_application(uuid,boolean,numeric),public.admin_review_product(uuid,boolean,numeric),public.request_vendor_withdrawal(numeric,text,text,text,text),public.review_vendor_withdrawal(uuid,text,text),public.my_vendor_summary(),public.company_network_summary() to authenticated;
grant execute on function public.lookup_side_referral(text) to anon,authenticated;


-- ===== schema/20261002102208_private_vendor_table_grants.sql =====
-- Supabase defaults may grant table access on creation. Bank details are private.
revoke all on public.vendor_income_ledger,public.vendor_withdrawals from public,anon;
grant select on public.vendor_income_ledger,public.vendor_withdrawals to authenticated;
notify pgrst, 'reload schema';


-- ===== schema/20261002111208_simple_admin_vendor_commissions.sql =====
-- Commission shares are percentages of negotiated commission, never of sale value.
insert into public.system_config(config_key,version,config_value,effective_from)
values('VENDOR_COMMISSION_SPLIT',1,'{"company":20,"buyer_discount":20,"affiliate":32,"sponsor":12,"second_upline":6,"introducer":10}',now());
alter table public.vendors drop constraint vendors_owner_user_id_key;
alter table public.vendors add constraint vendors_owner_brand_key unique(owner_user_id,business_name);
create unique index vendors_external_owner_key on public.vendors(owner_user_id) where not is_company_owned;
alter table public.vendors add column logo_url text, add column source_url text, add column introduced_by uuid references public.member_profiles(user_id);
update public.vendors set commission_rate=0 where is_company_owned;
alter table public.vendors add constraint company_commission_zero check(not is_company_owned or commission_rate=0);
-- Existing bootstrap remains retry safe when a company owns multiple brands.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.finish_operator_setup(uuid)'::regprocedure);
 execute replace(f,'on conflict(owner_user_id) do nothing','on conflict(owner_user_id,business_name) do nothing');
end $$;
alter table public.vendor_applications add column proposed_commission numeric(7,6) check(proposed_commission between 0 and 1), add column offered_commission numeric(7,6) check(offered_commission between 0 and 1), add column agreed_commission numeric(7,6) check(agreed_commission between 0 and 1), add column agreement_accepted_at timestamptz, add column terms_note text, add column introduced_by uuid references public.member_profiles(user_id);
alter table public.products add column image_urls jsonb not null default '[]' check(jsonb_typeof(image_urls)='array' and jsonb_array_length(image_urls)<=8), add column source_url text, add column source_details jsonb, add column review_note text;
alter table public.order_items add column company_owned_snapshot boolean, add column commission_split_snapshot jsonb, add column affiliate_id_snapshot uuid references public.member_profiles(user_id), add column sponsor_id_snapshot uuid references public.member_profiles(user_id), add column second_upline_id_snapshot uuid references public.member_profiles(user_id), add column introducer_id_snapshot uuid references public.member_profiles(user_id), add column commission_pool_pkr numeric(18,2), add column buyer_discount_pkr numeric(18,2) not null default 0;
alter table public.orders add column discount_pkr numeric(18,2) not null default 0;
create table public.commission_allocations(id uuid primary key default gen_random_uuid(),order_item_id uuid not null references public.order_items(id),share_kind text not null check(share_kind in('company','buyer_discount','affiliate','sponsor','second_upline','introducer')),beneficiary_id uuid references public.member_profiles(user_id),amount_pkr numeric(18,2) not null check(amount_pkr>=0),status text not null check(status in('discount_applied','earned','held','paid')),payment_reference text,reviewed_by uuid references auth.users(id),reviewed_at timestamptz,created_at timestamptz not null default now(),unique(order_item_id,share_kind));
create index commission_beneficiary_idx on public.commission_allocations(beneficiary_id,created_at desc);
alter table public.commission_allocations enable row level security;
create policy commission_read on public.commission_allocations for select to authenticated using(private.has_role('admin') or beneficiary_id=auth.uid());
revoke all on public.commission_allocations from public,anon,authenticated;
grant select on public.commission_allocations to authenticated;

create function public.set_commission_split(p_split jsonb) returns void language plpgsql security definer set search_path='' as $$
declare k text; total numeric:=0; ver int; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if jsonb_typeof(p_split)<>'object' or (select count(*) from jsonb_object_keys(p_split))<>6 then raise exception 'Enter all six commission shares'; end if;
 foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer'] loop
  if p_split->>k is null or (p_split->>k)::numeric<0 or (p_split->>k)::numeric>100 or (p_split->>k)::numeric<>round((p_split->>k)::numeric,2) then raise exception 'Invalid share'; end if;
  total:=total+(p_split->>k)::numeric;
 end loop;
 if total<>100 then raise exception 'Shares must add up to exactly 100 percent'; end if;
 perform pg_advisory_xact_lock(hashtextextended('commission-split',0));
 select coalesce(max(version),0)+1 into ver from public.system_config where config_key='VENDOR_COMMISSION_SPLIT';
 update public.system_config set effective_to=clock_timestamp() where config_key='VENDOR_COMMISSION_SPLIT' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('VENDOR_COMMISSION_SPLIT',ver,p_split,clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'COMMISSION_SPLIT_SET','system_config',p_split);
end $$;
create function public.submit_vendor_application(p_business text,p_email text,p_phone text,p_categories text,p_description text,p_proposed numeric,p_introducer_code text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare vid uuid; intro uuid; begin
 if auth.uid() is null or not exists(select 1 from public.member_profiles where user_id=auth.uid() and status='active') then raise exception 'Active member required'; end if;
 if length(trim(coalesce(p_business,''))) not between 2 and 150 or p_email not like '%@%' or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_categories,'')))<2 or p_proposed is null or p_proposed<0 or p_proposed>1 then raise exception 'Complete business details and proposed commission'; end if;
 if nullif(trim(p_introducer_code),'') is not null then
  select user_id into intro from public.member_profiles where status='active' and user_id<>auth.uid() and (upper(member_code)=upper(trim(p_introducer_code)) or upper(referral_code)=upper(trim(p_introducer_code)));
  if intro is null then raise exception 'Valid vendor introducer member code required'; end if;
 else select sponsor_id into intro from public.member_profiles where user_id=auth.uid(); end if;
 insert into public.vendor_applications(applicant_user_id,business_name,contact_email,contact_phone,categories,description,proposed_commission,introduced_by) values(auth.uid(),trim(p_business),trim(p_email),trim(p_phone),trim(p_categories),p_description,p_proposed,intro) returning id into vid;
 return vid;
end $$;
-- Proposed commissions cannot bypass agreement through direct client inserts.
revoke insert on public.vendor_applications from authenticated;
create function public.offer_vendor_commission(p_application_id uuid,p_rate numeric,p_note text) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_rate is null or p_rate<0 or p_rate>1 or p_rate<>round(p_rate,6) or length(trim(coalesce(p_note,'')))<5 then raise exception 'Enter rate and agreement terms'; end if;
 update public.vendor_applications set offered_commission=p_rate,agreed_commission=null,agreement_accepted_at=null,terms_note=trim(p_note) where id=p_application_id and status='pending';
 if not found then raise exception 'Pending application not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_TERMS_OFFERED','vendor_application',p_application_id,jsonb_build_object('rate',p_rate,'terms',p_note));
end $$;
create function public.accept_vendor_commission(p_application_id uuid) returns void language plpgsql security definer set search_path='' as $$ begin
 update public.vendor_applications set agreed_commission=offered_commission,agreement_accepted_at=now() where id=p_application_id and applicant_user_id=auth.uid() and status='pending' and offered_commission is not null;
 if not found then raise exception 'Company offer not found'; end if;
end $$;
create or replace function public.admin_review_vendor_application(p_application_id uuid,p_approve boolean,p_commission_rate numeric default null) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.vendor_applications%rowtype; vid uuid; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 select * into a from public.vendor_applications where id=p_application_id for update;
 if a.id is null or a.status<>'pending' then raise exception 'Pending application not found'; end if;
 if p_approve then
  if p_commission_rate is null or p_commission_rate<0 or p_commission_rate>1 or p_commission_rate<>round(p_commission_rate,6) then raise exception 'Set this vendor commission at approval'; end if;
  if a.proposed_commission is not null and (a.agreement_accepted_at is null or a.agreed_commission is distinct from p_commission_rate) then raise exception 'Vendor must accept these commission terms first'; end if;
  select id into vid from public.vendors where owner_user_id=a.applicant_user_id and not is_company_owned for update;
  if vid is null then
   insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,commission_rate,introduced_by,reviewed_by,reviewed_at) values(a.applicant_user_id,a.business_name,a.contact_email,a.contact_phone,a.description,'active',p_commission_rate,a.introduced_by,auth.uid(),now()) returning id into vid;
  else update public.vendors set business_name=a.business_name,contact_email=a.contact_email,contact_phone=a.contact_phone,description=a.description,status='active',commission_rate=p_commission_rate,introduced_by=a.introduced_by where id=vid; end if;
  insert into public.user_roles(user_id,role) values(a.applicant_user_id,'vendor') on conflict do nothing;
 end if;
 update public.vendor_applications set status=case when p_approve then 'active'::public.vendor_status else 'rejected'::public.vendor_status end,reviewed_by=auth.uid(),reviewed_at=now(),agreed_commission=case when p_approve then p_commission_rate else agreed_commission end where id=a.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_APPLICATION_REVIEWED','vendor_application',a.id,jsonb_build_object('approved',p_approve,'commission',p_commission_rate,'vendor',vid));
 return vid;
end $$;
create or replace function public.set_vendor_commission(p_vendor_id uuid,p_rate numeric) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_rate is null or p_rate<0 or p_rate>1 or p_rate<>round(p_rate,6) then raise exception 'Commission must be between 0 and 100 percent'; end if;
 if exists(select 1 from public.vendors where id=p_vendor_id and is_company_owned) and p_rate<>0 then raise exception 'Company brands have no commission'; end if;
 update public.vendors set commission_rate=p_rate where id=p_vendor_id and status='active';
 if not found then raise exception 'Active seller not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_COMMISSION_SET','vendor',p_vendor_id,jsonb_build_object('rate',p_rate));
end $$;
create or replace function public.admin_set_company_vendor(p_vendor_id uuid,p_company_owned boolean) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 update public.vendors set is_company_owned=p_company_owned,commission_rate=case when p_company_owned then 0 else commission_rate end where id=p_vendor_id and status='active';
 if not found then raise exception 'Active vendor not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'COMPANY_VENDOR_CLASSIFIED','vendor',p_vendor_id,jsonb_build_object('is_company_owned',p_company_owned));
end $$;
create function public.create_company_brand(p_name text,p_logo text default null,p_description text default '') returns uuid language plpgsql security definer set search_path='' as $$
declare vid uuid; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 150 or (nullif(p_logo,'') is not null and p_logo !~ '^https://') then raise exception 'Enter brand name and valid logo URL'; end if;
 insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,is_company_owned,commission_rate,logo_url,reviewed_by,reviewed_at) values(auth.uid(),trim(p_name),(select email from auth.users where id=auth.uid()),'',p_description,'active',true,0,nullif(p_logo,''),auth.uid(),now()) returning id into vid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'COMPANY_BRAND_CREATED','vendor',vid,jsonb_build_object('name',p_name));return vid;
end $$;
create function public.admin_vendor_status(p_vendor_id uuid,p_status text) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_status not in('active','suspended') then raise exception 'Invalid seller status'; end if;
 update public.vendors set status=p_status::public.vendor_status where id=p_vendor_id;
 if not found then raise exception 'Seller not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_STATUS_SET','vendor',p_vendor_id,jsonb_build_object('status',p_status));
end $$;
-- Photo metadata, name and price edits always return the listing to review.
create function public.save_product_listing(p_product_id uuid,p_vendor_id uuid,p_name text,p_sku text,p_description text,p_category text,p_price numeric,p_stock integer,p_images jsonb,p_submit boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid; begin
 if not exists(select 1 from public.vendors where id=p_vendor_id and status='active' and (owner_user_id=auth.uid() or private.has_role('admin'))) then raise exception 'Active seller access required'; end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 250 or length(trim(coalesce(p_description,'')))<5 or length(trim(coalesce(p_category,'')))<2 or p_price is null or p_price<=0 or p_price<>round(p_price,2) or p_stock is null or p_stock<0 or p_stock>1000000 or jsonb_typeof(p_images)<>'array' or jsonb_array_length(p_images)>8 or exists(select 1 from jsonb_array_elements_text(p_images) x where x !~ '^https://') then raise exception 'Complete product details, positive PKR price and up to eight photos'; end if;
 if p_submit and jsonb_array_length(p_images)=0 then raise exception 'Add at least one product photo before submitting'; end if;
 if p_product_id is null then
  insert into public.products(vendor_id,name,sku,description,category,price_pkr,stock_quantity,image_urls,image_url,status) values(p_vendor_id,trim(p_name),nullif(trim(p_sku),''),p_description,trim(p_category),p_price,p_stock,p_images,p_images->>0,case when p_submit then 'pending'::public.product_status else 'draft'::public.product_status end) returning id into pid;
 else
  update public.products set name=trim(p_name),sku=nullif(trim(p_sku),''),description=p_description,category=trim(p_category),price_pkr=p_price,stock_quantity=p_stock,image_urls=p_images,image_url=p_images->>0,status=case when p_submit then 'pending'::public.product_status else 'draft'::public.product_status end,updated_at=now() where id=p_product_id and vendor_id=p_vendor_id returning id into pid;
  if pid is null then raise exception 'Product not found'; end if;
  delete from public.featured_products where product_id=pid;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_LISTING_SAVED','product',pid,jsonb_build_object('submitted',p_submit));return pid;
end $$;
create function public.archive_product(p_product_id uuid) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 update public.products set status='archived',updated_at=now() where id=p_product_id;
 if not found then raise exception 'Product not found'; end if;
 delete from public.featured_products where product_id=p_product_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'PRODUCT_ARCHIVED','product',p_product_id);
end $$;
create or replace function public.admin_review_product(p_product_id uuid,p_approve boolean,p_ppv numeric default null) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_approve and (p_ppv is null or p_ppv<0 or p_ppv>1000000 or p_ppv<>round(p_ppv,4)) then raise exception 'Assign PPV to this product before approval'; end if;
 if p_approve and exists(select 1 from public.products where id=p_product_id and (price_pkr<=0 or stock_quantity<=0 or nullif(image_url,'') is null)) then raise exception 'Enter positive PKR price, available stock and a product photo before approval'; end if;
 update public.products set status=case when p_approve then 'approved'::public.product_status else 'rejected'::public.product_status end,ppv_per_unit=case when p_approve then p_ppv else ppv_per_unit end,updated_at=now() where id=p_product_id and status in('draft','pending','rejected','archived');
 if not found then raise exception 'Reviewable product not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_PPV_REVIEWED','product',p_product_id,jsonb_build_object('approved',p_approve,'ppv_per_unit',p_ppv));
end $$;

create function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$
declare v public.vendors%rowtype; aff text; begin
 select * into v from public.vendors where id=new.vendor_id;
 new.company_owned_snapshot:=v.is_company_owned;
 new.commission_rate_snapshot:=case when v.is_company_owned then 0 else v.commission_rate end;
 if new.commission_rate_snapshot is null then raise exception 'Vendor commission is awaiting agreement'; end if;
 select config_value into new.commission_split_snapshot from public.system_config where config_key='VENDOR_COMMISSION_SPLIT' and effective_to is null order by version desc limit 1;
 new.commission_pool_pkr:=round(new.unit_price_pkr*new.quantity*new.commission_rate_snapshot,2);
 new.buyer_discount_pkr:=round(new.commission_pool_pkr*(new.commission_split_snapshot->>'buyer_discount')::numeric/100,2);
 aff:=nullif(current_setting('mio.affiliate_code',true),'');
 if not v.is_company_owned and aff is not null then
  select user_id,sponsor_id into new.affiliate_id_snapshot,new.sponsor_id_snapshot from public.member_profiles where status='active' and (upper(member_code)=upper(aff) or upper(referral_code)=upper(aff));
  if new.affiliate_id_snapshot is null then raise exception 'Affiliate code not found'; end if;
  if new.affiliate_id_snapshot=(select buyer_id from public.orders where id=new.order_id) then raise exception 'Buyer cannot claim their own affiliate sale'; end if;
  select sponsor_id into new.second_upline_id_snapshot from public.member_profiles where user_id=new.sponsor_id_snapshot;
 end if;
 new.introducer_id_snapshot:=case when v.is_company_owned then null else v.introduced_by end;
 return new;
end $$;
create trigger snapshot_commission before insert on public.order_items for each row execute function private.snapshot_commission();
create or replace function public.place_marketplace_order(p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare oid uuid; fee numeric; disc numeric; gross numeric; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended('order-policy:'||auth.uid()::text||':'||p_idempotency_key,0));
 select id into oid from public.orders where buyer_id=auth.uid() and idempotency_key=p_idempotency_key;
 if oid is not null then return oid; end if;
 select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
 if fee is null then raise exception 'Delivery charges are awaiting company configuration'; end if;
 oid:=private.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 select coalesce(sum(buyer_discount_pkr),0),sum(line_total_pkr) into disc,gross from public.order_items where order_id=oid;
 update public.orders set discount_pkr=disc,subtotal_pkr=gross-disc,delivery_fee_pkr=fee,total_pkr=gross-disc+fee where id=oid;
 return oid;
end $$;
create function public.place_affiliate_order(p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,p_idempotency_key text,p_affiliate_code text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare oid uuid; begin
 perform set_config('mio.affiliate_code',coalesce(trim(p_affiliate_code),''),true);
 oid:=public.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 perform set_config('mio.affiliate_code','',true);return oid;
end $$;
create or replace function private.post_vendor_sale() returns trigger language plpgsql security definer set search_path='' as $$
declare i public.order_items%rowtype; pool numeric; k text; amt numeric; cumul numeric; previous numeric; beneficiary uuid; state text; begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  for i in select * from public.order_items where order_id=new.id loop
   pool:=coalesce(i.commission_pool_pkr,round(i.line_total_pkr*i.commission_rate_snapshot,2),0);
   insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr) values(i.vendor_id,i.id,i.line_total_pkr,pool,i.line_total_pkr-pool) on conflict(order_item_id) do nothing;
   if pool<=0 or i.commission_split_snapshot is null then continue; end if;
   cumul:=0;previous:=0;
   -- Buyer first ensures receipt discount equals ledger discount; final share absorbs cents.
   foreach k in array array['buyer_discount','company','affiliate','sponsor','second_upline','introducer'] loop
    cumul:=cumul+(i.commission_split_snapshot->>k)::numeric;
    amt:=round(pool*cumul/100,2)-previous; previous:=previous+amt;
    beneficiary:=case k when 'buyer_discount' then new.buyer_id when 'company' then (select company_id from private.network_foundation limit 1) when 'affiliate' then i.affiliate_id_snapshot when 'sponsor' then i.sponsor_id_snapshot when 'second_upline' then i.second_upline_id_snapshot when 'introducer' then i.introducer_id_snapshot end;
    state:=case when k='buyer_discount' then 'discount_applied' when beneficiary is null then 'held' else 'earned' end;
    insert into public.commission_allocations(order_item_id,share_kind,beneficiary_id,amount_pkr,status) values(i.id,k,beneficiary,amt,state) on conflict(order_item_id,share_kind) do nothing;
   end loop;
  end loop;
 end if;return new;
end $$;
create function public.record_commission_payment(p_allocation_id uuid,p_reference text) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if length(trim(coalesce(p_reference,'')))<10 then raise exception 'Record actual bank payment reference'; end if;
 update public.commission_allocations set status='paid',payment_reference=trim(p_reference),reviewed_by=auth.uid(),reviewed_at=now() where id=p_allocation_id and status='earned' and beneficiary_id is not null and share_kind not in('buyer_discount','company');
 if not found then raise exception 'Payable earned allocation not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'COMMISSION_PAYMENT_RECORDED','commission_allocation',p_allocation_id,jsonb_build_object('reference',p_reference));
end $$;
-- Image uploads use random immutable paths under the chosen vendor. Public photos only.
do $$ begin
 if to_regclass('storage.buckets') is not null then
  execute $q$insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('product-images','product-images',true,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing$q$;
  execute $q$create policy product_photo_upload on storage.objects for insert to authenticated with check(bucket_id='product-images' and exists(select 1 from public.vendors v where v.id::text=split_part(name,'/',1) and v.status='active' and (v.owner_user_id=auth.uid() or private.has_role('admin'))))$q$;
  execute $q$create policy product_photo_owner_read on storage.objects for select to authenticated using(bucket_id='product-images' and exists(select 1 from public.vendors v where v.id::text=split_part(name,'/',1) and (v.owner_user_id=auth.uid() or private.has_role('admin'))))$q$;
 end if;
end $$;
revoke all on function private.snapshot_commission() from public,anon,authenticated;
revoke all on function public.set_commission_split(jsonb),public.submit_vendor_application(text,text,text,text,text,numeric,text),public.offer_vendor_commission(uuid,numeric,text),public.accept_vendor_commission(uuid),public.create_company_brand(text,text,text),public.admin_vendor_status(uuid,text),public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean),public.archive_product(uuid),public.place_affiliate_order(jsonb,text,text,text,text,text,text),public.record_commission_payment(uuid,text) from public,anon;
grant execute on function public.set_commission_split(jsonb),public.submit_vendor_application(text,text,text,text,text,numeric,text),public.offer_vendor_commission(uuid,numeric,text),public.accept_vendor_commission(uuid),public.create_company_brand(text,text,text),public.admin_vendor_status(uuid,text),public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean),public.archive_product(uuid),public.place_affiliate_order(jsonb,text,text,text,text,text,text),public.record_commission_payment(uuid,text) to authenticated;
notify pgrst,'reload schema';
-- Company and external sellers can switch brands without mixing their balances.
create function public.my_brand_summary(p_vendor_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$ begin
 if not exists(select 1 from public.vendors where id=p_vendor_id and (owner_user_id=auth.uid() or private.has_role('admin'))) then raise exception 'Seller access required'; end if;
 return jsonb_build_object('sales_pkr',coalesce((select sum(gross_pkr) from public.vendor_income_ledger where vendor_id=p_vendor_id),0),'commission_pkr',coalesce((select sum(commission_pkr) from public.vendor_income_ledger where vendor_id=p_vendor_id),0),'income_pkr',coalesce((select sum(net_pkr) from public.vendor_income_ledger where vendor_id=p_vendor_id),0),'reserved_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=p_vendor_id and status in('pending','approved')),0),'paid_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=p_vendor_id and status='paid'),0));
end $$;
do $$ declare f text; begin
 f:=pg_get_functiondef('public.request_vendor_withdrawal(numeric,text,text,text,text)'::regprocedure);
 execute replace(f,'where owner_user_id=auth.uid() and status=''active'' for update','where owner_user_id=auth.uid() and status=''active'' and (nullif(current_setting(''mio.selected_vendor'',true),'''') is null or id::text=current_setting(''mio.selected_vendor'',true)) order by created_at,id limit 1 for update');
end $$;
create function public.request_brand_withdrawal(p_vendor_id uuid,p_amount numeric,p_bank text,p_account_name text,p_account_number text,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$ declare wid uuid; begin
 if not exists(select 1 from public.vendors where id=p_vendor_id and owner_user_id=auth.uid() and status='active') then raise exception 'Active seller access required'; end if;
 perform set_config('mio.selected_vendor',p_vendor_id::text,true);
 wid:=public.request_vendor_withdrawal(p_amount,p_bank,p_account_name,p_account_number,p_idempotency_key);
 perform set_config('mio.selected_vendor','',true);return wid;
end $$;
revoke all on function public.my_brand_summary(uuid),public.request_brand_withdrawal(uuid,numeric,text,text,text,text) from public,anon;
grant execute on function public.my_brand_summary(uuid),public.request_brand_withdrawal(uuid,numeric,text,text,text,text) to authenticated;
create function private.guard_company_commission() returns trigger language plpgsql security definer set search_path='' as $$ begin
 if new.is_company_owned then
  if coalesce(new.commission_rate,0)<>0 then raise exception 'Company brands have no commission'; end if;
  new.commission_rate:=0;
 end if;return new;
end $$;
create trigger guard_company_commission before insert or update on public.vendors for each row execute function private.guard_company_commission();
revoke all on function private.guard_company_commission() from public,anon,authenticated;
create function public.resolve_commission_recipient(p_allocation_id uuid,p_member_code text,p_reason text) returns void language plpgsql security definer set search_path='' as $$ declare uid uuid; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if length(trim(coalesce(p_reason,'')))<20 then raise exception 'Record how you verified the missing recipient'; end if;
 select user_id into uid from public.member_profiles where status='active' and upper(member_code)=upper(trim(p_member_code));
 if uid is null then raise exception 'Active member code required'; end if;
 if exists(select 1 from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.id=p_allocation_id and a.share_kind='affiliate' and o.buyer_id=uid) then raise exception 'Buyer cannot claim own affiliate sale'; end if;
 update public.commission_allocations set beneficiary_id=uid,status='earned',reviewed_by=auth.uid(),reviewed_at=now() where id=p_allocation_id and status='held' and beneficiary_id is null and share_kind in('affiliate','sponsor','second_upline','introducer');
 if not found then raise exception 'Held allocation not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'COMMISSION_RECIPIENT_RESOLVED','commission_allocation',p_allocation_id,jsonb_build_object('recipient',uid,'verification',p_reason));
end $$;
create function public.manage_member_account(p_member_id uuid,p_name text,p_phone text,p_status text,p_reason text) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if p_status not in('active','suspended') or length(trim(coalesce(p_name,'')))<2 or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_reason,'')))<10 then raise exception 'Complete member details, status and reason'; end if;
 if exists(select 1 from public.user_roles where user_id=p_member_id and role='admin') or exists(select 1 from private.network_foundation where founder_id=p_member_id) then raise exception 'Company and founder accounts are protected'; end if;
 update public.member_profiles set full_name=trim(p_name),phone=trim(p_phone),status=p_status::public.account_status,updated_at=now() where user_id=p_member_id and status in('active','suspended');
 if not found then raise exception 'Active or suspended member not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'MEMBER_ACCOUNT_MANAGED','member_profile',p_member_id,jsonb_build_object('name',p_name,'status',p_status,'reason',p_reason));
end $$;
create or replace function public.company_network_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 return jsonb_build_object('founder',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.founder_id where n.company_id=auth.uid()),'binary_retention_mio',coalesce((select sum(company_retention) from public.binary_member_results),0),'seller_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind='company'),0),'package_fees_mio',coalesce((select sum(company_fee) from public.package_activations where status='approved'),0));
end $$;
revoke all on function public.resolve_commission_recipient(uuid,text,text),public.manage_member_account(uuid,text,text,text,text) from public,anon;
grant execute on function public.resolve_commission_recipient(uuid,text,text),public.manage_member_account(uuid,text,text,text,text) to authenticated;
notify pgrst,'reload schema';
-- Zero PPV is a valid explicit admin decision; do not write zero ledger entries.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.admin_confirm_order_payment(uuid)'::regprocedure);
 f:=replace(f,'  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)','  if ppv_value>0 then'||chr(10)||'  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)');
 f:=replace(f,'    on conflict(idempotency_key) do nothing;'||chr(10)||'  select coalesce(sum(amount),0) into current_ppv','    on conflict(idempotency_key) do nothing;'||chr(10)||'  end if;'||chr(10)||'  select coalesce(sum(amount),0) into current_ppv');
 execute f;
end $$;


-- ===== schema/20261002122648_product_stock_policy.sql =====
-- Initial inventory and restock entry policy; checkout depletion remains normal.
alter table public.products alter column stock_quantity set default 300;
create function private.guard_stock_entry() returns trigger language plpgsql security invoker set search_path='' as $$ begin
 if current_user in('authenticated','anon') and (tg_op='INSERT' or new.stock_quantity is distinct from old.stock_quantity) and new.stock_quantity<200 then
  raise exception 'Stock entries require at least 200 units; default stock is 300';
 end if;
 return new;
end $$;
create trigger guard_stock_entry before insert or update of stock_quantity on public.products for each row execute function private.guard_stock_entry();
revoke all on function private.guard_stock_entry() from public,anon,authenticated;
-- Trusted inventory RPCs validate entry quantities; order reservation does not use these.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean)'::regprocedure);
 f:=replace(f,'p_stock<0','p_stock<200');
 f:=replace(f,'Complete product details, positive PKR price and up to eight photos','Complete product details, positive PKR price, at least 200 stock units and up to eight photos');
 execute f;
 f:=pg_get_functiondef('public.update_seller_inventory(uuid,numeric,integer)'::regprocedure);
 f:=replace(f,'p_stock<0','p_stock<200');
 f:=replace(f,'Invalid price or stock quantity','Enter a valid price and at least 200 stock units');
 execute f;
end $$;
notify pgrst,'reload schema';


-- ===== schema/20261002123551_vendor_proposal_and_referral_rules.sql =====
-- External vendor application starts at the company's required 20% proposal.
-- Active accounts retain their known inviter; no redundant code or lineage override.
create or replace function public.submit_vendor_application(p_business text,p_email text,p_phone text,p_categories text,p_description text,p_proposed numeric,p_introducer_code text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare vid uuid; intro uuid; m public.member_profiles%rowtype; consumer boolean; begin
 if auth.uid() is null then raise exception 'Sign in or register with a referral code before applying'; end if;
 select * into m from public.member_profiles where user_id=auth.uid();
 if m.user_id is null or m.status in('suspended','closed') then raise exception 'Active account required'; end if;
 consumer:=exists(select 1 from public.package_activations where member_id=auth.uid() and status='approved');
 if m.status<>'active' and not consumer then raise exception 'Complete account registration with your referral code first'; end if;
 if length(trim(coalesce(p_business,''))) not between 2 and 150 or p_email not like '%@%' or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_categories,'')))<2 then raise exception 'Complete business details'; end if;
 if p_proposed is distinct from 0.20 then raise exception 'Proposed vendor commission must be 20 percent'; end if;
 intro:=m.sponsor_id;
 insert into public.vendor_applications(applicant_user_id,business_name,contact_email,contact_phone,categories,description,proposed_commission,introduced_by) values(auth.uid(),trim(p_business),trim(p_email),trim(p_phone),trim(p_categories),p_description,0.20,intro) returning id into vid;
 return vid;
end $$;
alter table public.products add column compare_at_price_pkr numeric(14,2) check(compare_at_price_pkr>=0);
alter table public.order_items add column compare_at_price_pkr_snapshot numeric(14,2),add column retail_saving_pkr numeric(18,2) not null default 0;
create function private.snapshot_retail_price() returns trigger language plpgsql security definer set search_path='' as $$ begin
 select compare_at_price_pkr into new.compare_at_price_pkr_snapshot from public.products where id=new.product_id;
 new.retail_saving_pkr:=greatest(coalesce(new.compare_at_price_pkr_snapshot,new.unit_price_pkr)-new.unit_price_pkr,0)*new.quantity;
 return new;
end $$;
create trigger snapshot_retail_price before insert on public.order_items for each row execute function private.snapshot_retail_price();
revoke all on function private.snapshot_retail_price() from public,anon,authenticated;
-- Published compare-at values describe source sale prices, never a second deduction.
notify pgrst,'reload schema';


-- ===== schema/20261002130900_vendor_sale_funded_rewards.sql =====
-- Percentages below are percentages of discounted merchandise sale, excluding shipping.
alter table public.vendors drop constraint company_commission_zero;
alter table public.vendors add column sale_distribution jsonb;
alter table public.order_items add column distribution_basis text not null default 'legacy_commission';
alter table public.commission_allocations drop constraint commission_allocations_share_kind_check;
alter table public.commission_allocations add constraint commission_allocations_share_kind_check check(share_kind in('company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'));
alter table public.commission_allocations drop constraint commission_allocations_status_check;
alter table public.commission_allocations add constraint commission_allocations_status_check check(status in('discount_applied','earned','held','paid','reserved'));

create function private.valid_sale_distribution(p jsonb, rate numeric) returns boolean language plpgsql immutable set search_path='' as $$
declare k text; total numeric:=0; x numeric; begin
 if p is null or jsonb_typeof(p)<>'object' or (select count(*) from jsonb_object_keys(p))<>8 or rate is null or rate<0.05 or rate>1 then return false; end if;
 foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'] loop
  x:=(p->>k)::numeric; if x is null or x<0 or x>100 or x<>round(x,4) then return false; end if; total:=total+x;
 end loop;
 return (p->>'company')::numeric=5 and total=rate*100;
exception when others then return false; end $$;
create or replace function private.guard_company_commission() returns trigger language plpgsql security definer set search_path='' as $$ begin
 if new.is_company_owned and coalesce(new.commission_rate,0)=0 then new.commission_rate:=0.05; end if;
 if new.commission_rate>=0.05 and not private.valid_sale_distribution(new.sale_distribution,new.commission_rate) then
  new.sale_distribution:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',0,'unallocated',new.commission_rate*100-5);
 end if; return new; end $$;
update public.vendors set commission_rate=0.05 where is_company_owned;
update public.vendors set sale_distribution=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',0,'unallocated',commission_rate*100-5) where commission_rate>=0.05;
update public.vendors set commission_rate=0.30,sale_distribution='{"company":5,"buyer_discount":0,"affiliate":0,"sponsor":0,"second_upline":0,"introducer":0,"network_rewards":25,"unallocated":0}' where is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%';

create function public.set_vendor_sale_distribution(p_vendor_id uuid,p_split jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r numeric; before_row jsonb; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 select commission_rate,to_jsonb(v) into r,before_row from public.vendors v where id=p_vendor_id for update;
 if not private.valid_sale_distribution(p_split,r) then raise exception 'Company must receive 5%% of sale; all sale percentages must total the agreed commission'; end if;
 update public.vendors set sale_distribution=p_split where id=p_vendor_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'VENDOR_SALE_DISTRIBUTION','vendor',p_vendor_id,before_row,p_split);
end $$;
create or replace function public.set_commission_split(p_split jsonb) returns void language plpgsql security definer set search_path='' as $$ begin raise exception 'Select a vendor and configure percentages of sale'; end $$;
create or replace function public.set_vendor_commission(p_vendor_id uuid,p_rate numeric) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if p_rate is null or p_rate<0.05 or p_rate>1 or p_rate<>round(p_rate,6) then raise exception 'Agreed commission must cover company 5 percent of sale'; end if;
 update public.vendors set commission_rate=p_rate,sale_distribution=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',0,'unallocated',p_rate*100-5) where id=p_vendor_id;
 if not found then raise exception 'Vendor not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_COMMISSION','vendor',p_vendor_id,jsonb_build_object('rate',p_rate,'remaining','held until vendor distribution saved'));
end $$;

create or replace function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$
declare v public.vendors%rowtype; aff text; begin
 select * into v from public.vendors where id=new.vendor_id;
 if not private.valid_sale_distribution(v.sale_distribution,v.commission_rate) then raise exception 'Vendor sale distribution is awaiting company review'; end if;
 new.company_owned_snapshot:=v.is_company_owned; new.commission_rate_snapshot:=v.commission_rate;
 new.commission_split_snapshot:=v.sale_distribution; new.distribution_basis:='sale_v2';
 new.commission_pool_pkr:=round(new.unit_price_pkr*new.quantity*v.commission_rate,2);
 new.buyer_discount_pkr:=least(round(new.unit_price_pkr*new.quantity*(v.sale_distribution->>'buyer_discount')::numeric/100,2),greatest(0,new.commission_pool_pkr-round(new.unit_price_pkr*new.quantity*0.05,2)));
 aff:=nullif(current_setting('mio.affiliate_code',true),'');
 -- Product affiliate is separate from the buyer's permanent sponsor genealogy.
 if aff is not null then
  select user_id,sponsor_id into new.affiliate_id_snapshot,new.sponsor_id_snapshot from public.member_profiles where status='active' and (upper(member_code)=upper(aff) or upper(referral_code)=upper(aff));
  if new.affiliate_id_snapshot is null then raise exception 'Affiliate code not found'; end if;
  if new.affiliate_id_snapshot=(select buyer_id from public.orders where id=new.order_id) then raise exception 'Buyer cannot claim their own affiliate sale'; end if;
  select sponsor_id into new.second_upline_id_snapshot from public.member_profiles where user_id=new.sponsor_id_snapshot;
 end if;
 new.introducer_id_snapshot:=v.introduced_by; return new;
end $$;

create table public.shopping_reward_events(
 order_id uuid primary key references public.orders(id),buyer_id uuid not null references public.member_profiles(user_id),
 funded_pkr numeric(18,2) not null check(funded_pkr>=0),bv numeric(18,4) not null check(bv>=0),
 direct_generation_mio numeric(18,4) not null default 0,single_line_mio numeric(18,4) not null default 0,
 binary_reserve_mio numeric(18,4) not null,created_at timestamptz not null default now(),
 check(direct_generation_mio>=0 and direct_generation_mio<=trunc(bv*0.55,4)),
 check(single_line_mio>=0 and single_line_mio<=trunc(bv*0.10,4)),
 check(binary_reserve_mio=trunc(bv*0.35,4)),
 check((direct_generation_mio+single_line_mio+binary_reserve_mio)*300<=funded_pkr));
alter table public.shopping_reward_events enable row level security;
create policy shopping_rewards_read on public.shopping_reward_events for select to authenticated using(buyer_id=auth.uid() or private.has_role('admin'));
revoke all on public.shopping_reward_events from public,anon,authenticated;
grant select on public.shopping_reward_events to authenticated;
create index shopping_rewards_buyer_time on public.shopping_reward_events(buyer_id,created_at);
create index shopping_rewards_time on public.shopping_reward_events(created_at);
alter table public.bonus_transactions add column source_order_id uuid references public.orders(id);
create index bonus_order_source on public.bonus_transactions(source_order_id) where source_order_id is not null;
alter table public.bonus_transactions drop constraint bonus_transactions_check;
alter table public.bonus_transactions add constraint bonus_source_check check((method='binary_pool_share' and cycle_id is not null and num_nonnulls(source_activation_id,source_order_id)=0) or (method<>'binary_pool_share' and cycle_id is null and num_nonnulls(source_activation_id,source_order_id)=1));
alter table public.mio_ledger add column source_order_id uuid references public.orders(id);
create index mio_order_source on public.mio_ledger(source_order_id) where source_order_id is not null;
alter table public.mio_ledger drop constraint mio_ledger_bonus_source_check;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check check((action in('package_activation','bonus_credit') and num_nonnulls(activation_id,cycle_id,source_order_id)=1) or (action not in('package_activation','bonus_credit') and num_nonnulls(activation_id,cycle_id,source_order_id)=0));

-- Shared list of qualified sponsor rewards. Gen1 never stacks with direct.
create function private.sale_reward_candidates(member uuid,bv numeric) returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric) language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)
 ), recipients as(
  select u.*,p.max_generations from up u join public.member_profiles m on m.user_id=u.id and m.status='active'
  cross join lateral(select pv.max_generations from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version where a.member_id=u.id and a.status='approved' order by a.activated_at desc,a.requested_at desc limit 1)p where u.depth>0
 ) select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
 bv*case when depth=1 then coalesce((select pv.direct_rate from public.package_versions pv where pv.package_code=coalesce(private.current_package_code(member),'BASIC_1') and pv.is_active order by version desc limit 1),0.20) else 0.05 end from recipients where depth=1 or depth<=max_generations;
$$;
create function private.post_shopping_bonus(oid uuid,beneficiary uuid,method public.bonus_method,depth integer,base numeric,nominal numeric,amount numeric) returns void language plpgsql security definer set search_path='' as $$
declare tx uuid; begin
 if amount<=0 then return; end if;
 insert into public.bonus_transactions(beneficiary_id,method,source_order_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
 values(beneficiary,method,oid,depth,base,case when base>0 then amount/base else 0 end,nominal,amount,'MIO','sale-funded-v2',jsonb_build_object('sale_budget_pkr_per_mio',300,'nominal_mio',nominal,'funded_payable_mio',amount,'method_cap',case when method='single_line' then 0.10 else 0.55 end),'shopping:'||oid||':'||method||':'||beneficiary||':'||depth) on conflict(idempotency_key) do nothing returning id into tx;
 if tx is not null then
  update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=beneficiary;
  if not found then raise exception 'Recipient wallet missing'; end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,bonus_transaction_id,reason,idempotency_key) values(beneficiary,amount,'bonus_credit',oid,tx,'Shopping BV funded bonus','bonus:'||tx);
 end if;
end $$;
create function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$
declare buyer uuid; funding numeric; b numeric; r record; total numeric; scale numeric; paid numeric:=0; single_paid numeric:=0; amount numeric; p uuid; side text; current_member uuid; depth int:=0; lim int; begin
 select buyer_id into buyer from public.orders where id=oid and payment_status='confirmed';
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=oid and a.share_kind='network_rewards';
 b:=trunc(funding/300,4); if b<=0 then return; end if;
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(oid,buyer,funding,b,trunc(b*0.35,4)) on conflict do nothing;
 if not found then return; end if;
 insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
 select buyer,k,case when k in('BV','DP') then b else trunc(b/2,4) end,oid,'credit','shopping:'||oid||':'||k from unnest(array['BV','DP','GP','BRP']) k where case when k in('BV','DP') then b else trunc(b/2,4) end>0;
 select coalesce(sum(nominal),0) into total from private.sale_reward_candidates(buyer,b);
 scale:=case when total>0 then least(1,trunc(b*0.55,4)/total) else 0 end;
 for r in select * from private.sale_reward_candidates(buyer,b) order by depth loop
  amount:=trunc(r.nominal*scale,4); perform private.post_shopping_bonus(oid,r.beneficiary,r.method,r.depth,b,r.nominal,amount);paid:=paid+amount;
 end loop;
 current_member:=buyer;
 loop
  select parent_id,bp.side into p,side from public.binary_placements bp where bp.member_id=current_member;
  exit when p is null; depth:=depth+1;
  if depth>100 then raise exception 'Binary ancestry exceeds limit'; end if;
  if trunc(b/2,4)>0 then insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(b/2,4),side,oid,'credit','shopping-bp:'||oid||':'||p); end if;
  lim:=case private.current_package_code(p) when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 when 'PREMIUM' then 30 else 0 end;
  if depth<=lim and exists(select 1 from public.member_profiles where user_id=p and status='active') then
   amount:=trunc(b*depth/300,4)-trunc(b*(depth-1)/300,4);
   perform private.post_shopping_bonus(oid,p,'single_line',depth,b,b/300,amount); single_paid:=single_paid+amount;
  end if;
  current_member:=p;
 end loop;
 update public.shopping_reward_events set direct_generation_mio=paid,single_line_mio=single_paid where order_id=oid;
end $$;

-- Preserve the old implementation for immutable legacy snapshots.
alter function private.post_vendor_sale() rename to post_vendor_sale_legacy;
create function private.post_vendor_sale() returns trigger language plpgsql security definer set search_path='' as $$
declare i public.order_items%rowtype; cumul numeric; previous numeric; k text; amount numeric; beneficiary uuid; state text; rate numeric; begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  for i in select * from public.order_items where order_id=new.id loop
   if i.distribution_basis<>'sale_v2' then raise exception 'Legacy unpaid order requires explicit reconciliation'; end if;
   insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr) values(i.vendor_id,i.id,i.line_total_pkr,i.commission_pool_pkr,i.line_total_pkr-i.commission_pool_pkr) on conflict(order_item_id) do nothing;
   cumul:=0;previous:=0;
   foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'] loop
    rate:=(i.commission_split_snapshot->>k)::numeric;cumul:=cumul+rate;
    amount:=case k when 'company' then round(i.line_total_pkr*0.05,2) when 'buyer_discount' then i.buyer_discount_pkr else greatest(0,least(i.commission_pool_pkr-previous,round(i.line_total_pkr*cumul/100,2)-previous)) end; previous:=previous+amount;
    beneficiary:=case k when 'buyer_discount' then new.buyer_id when 'company' then (select company_id from private.network_foundation limit 1) when 'affiliate' then i.affiliate_id_snapshot when 'sponsor' then i.sponsor_id_snapshot when 'second_upline' then i.second_upline_id_snapshot when 'introducer' then i.introducer_id_snapshot end;
    state:=case when k='buyer_discount' then 'discount_applied' when k='network_rewards' then 'reserved' when beneficiary is null then 'held' else 'earned' end;
    if amount>0 then insert into public.commission_allocations(order_item_id,share_kind,beneficiary_id,amount_pkr,status) values(i.id,k,beneficiary,amount,state) on conflict(order_item_id,share_kind) do nothing; end if;
   end loop;
   if previous<>i.commission_pool_pkr then raise exception 'Sale allocation does not reconcile'; end if;
  end loop;
  perform private.post_shopping_rewards(new.id);
 end if; return new;
end $$;
drop trigger post_vendor_sale on public.orders;
create trigger post_vendor_sale after update of payment_status on public.orders for each row execute function private.post_vendor_sale();

-- Shopping activations grant package eligibility, not a second funded event.
do $$ declare f text; name text; begin
 foreach name in array array['private.credit_activation_bonuses(uuid)','private.credit_single_line(uuid)','private.credit_binary_volume(uuid)'] loop
  f:=pg_get_functiondef(name::regprocedure);
  if name like '%credit_activation_bonuses%' then f:=replace(f,'if act.id is null or act.status<>''approved'' then return 0; end if;','if act.id is null or act.status<>''approved'' or act.source=''SHOPPING_PPV'' then return 0; end if;');
  elsif name like '%credit_single_line%' then f:=replace(f,'if a.id is null then return; end if;','if a.id is null or a.source=''SHOPPING_PPV'' then return; end if;');
  else f:=replace(f,'if act.id is null or act.bp<=0 then return 0; end if;','if act.id is null or act.bp<=0 or act.source=''SHOPPING_PPV'' then return 0; end if;'); end if;
  execute f;
 end loop;
 f:=pg_get_functiondef('private.assign_activation_points()'::regprocedure);
 execute replace(f,'if new.status=''approved'' then','if new.status=''approved'' and new.source<>''SHOPPING_PPV'' then');
 f:=pg_get_functiondef('private.activate_next_ppv_package(uuid,uuid,numeric)'::regprocedure);
 f:=replace(f,'    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)'||chr(10)||'      values(p_member_id,''PPV'',p.ppv,aid,''credit'',id_key || '':ppv'');','    -- Activation never mints additional shopping PPV.');
 f:=replace(f,'    p_cumulative_ppv := p_cumulative_ppv+p.ppv;','    -- No synthetic PPV increase.');execute f;
end $$;

-- Bound new paid-package direct+generation to the 55% remaining after binary35/SL10.
do $$ declare f text; begin
 f:=pg_get_functiondef('private.credit_activation_bonuses(uuid)'::regprocedure);
 f:=replace(f,'  stack_gen1 boolean := false;','  stack_gen1 boolean := false;'||chr(10)||'  candidate_total numeric; funding_scale numeric:=1;');
 f:=replace(f,'  if direct_sponsor is not null and exists',
 '  select coalesce(sum(nominal),0) into candidate_total from private.sale_reward_candidates(act.member_id,act.bv);'||chr(10)||
 '  if stack_gen1 then candidate_total:=candidate_total+act.bv*0.30; end if;'||chr(10)||
 '  funding_scale:=case when candidate_total>0 then least(1,trunc(least(act.bv,act.base_value,act.payable_price-act.company_fee)*0.55,4)/candidate_total) else 1 end;'||chr(10)||
 '  if direct_sponsor is not null and exists');
 f:=replace(f,'payout := round(act.bv*act.direct_rate,4);','payout := trunc(act.bv*act.direct_rate*funding_scale,4);');
 f:=replace(f,'payout := round(act.bv*rate,4);','payout := trunc(act.bv*rate*funding_scale,4);');
 f:=replace(f,'''phase1-direct-v1''','''funded-direct-v2''');f:=replace(f,'''phase1-generation-v1''','''funded-generation-v2''');
 f:=replace(f,'''source_package'',act.package_code','''funding_scale'',funding_scale,''direct_generation_cap'',0.55,''source_package'',act.package_code');execute f;
end $$;

-- Weekly pool consumes actual paid shopping events, not PPV activation package values.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.admin_close_binary_cycle(text,timestamptz,timestamptz,text)'::regprocedure);
 f:=replace(f,'where status=''approved'' and activated_at>=p_starts_at and activated_at<p_ends_at;',
 'where status=''approved'' and source<>''SHOPPING_PPV'' and activated_at>=p_starts_at and activated_at<p_ends_at;');
 f:=replace(f,'sum(base_value)','sum(least(base_value,bv,payable_price-company_fee))');
 f:=replace(f,' pool:=round(eligible*0.35,4);',
 ' pool:=trunc(eligible*0.35,4)+(select coalesce(sum(binary_reserve_mio),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);'||chr(10)||
 '  eligible:=eligible+(select coalesce(sum(bv),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);');
 f:=replace(f,'from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id',
 'from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id');
 f:=replace(f,'where pl.point_type=''BP'' and a.status=''approved'' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at',
 'where pl.point_type=''BP'' and ((a.status=''approved'' and a.source<>''SHOPPING_PPV'' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at) or (s.created_at>=p_starts_at and s.created_at<p_ends_at))');
 f:=replace(f,'where pl.point_type=''BP'' and a.status=''approved'' and a.activated_at<p_ends_at and pl.created_at<=now()',
 'where pl.point_type=''BP'' and ((a.status=''approved'' and a.source<>''SHOPPING_PPV'' and a.activated_at<p_ends_at) or s.created_at<p_ends_at) and pl.created_at<=now()');
 execute f;
end $$;

-- A locked source event enforces caps even if later rates change unexpectedly.
create function private.guard_bonus_funding() returns trigger language plpgsql security definer set search_path='' as $$
declare b numeric; spent numeric; ceiling numeric; begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new; end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid'; end if;
 if new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status='posted';
 else
  if new.source_order_id is not null then select bv into b from public.shopping_reward_events where order_id=new.source_order_id for update;
  else select least(bv,base_value,payable_price-company_fee) into b from public.package_activations where id=new.source_activation_id and status='approved' and source<>'SHOPPING_PPV' for update; end if;
  ceiling:=trunc(b*case when new.method='single_line' then 0.10 else 0.55 end,4);
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where status='posted' and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id)) and case when new.method='single_line' then method='single_line' else method in('direct','generation') end;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling then raise exception 'Bonus would exceed its funded source budget'; end if;return new;
end $$;
create trigger guard_bonus_funding before insert on public.bonus_transactions for each row execute function private.guard_bonus_funding();
revoke all on function private.guard_bonus_funding() from public,anon,authenticated;
do $$ declare f text; name text; begin
 foreach name in array array['public.resolve_commission_recipient(uuid,text,text)','public.record_commission_payment(uuid,text)'] loop
  f:=pg_get_functiondef(name::regprocedure);
  f:=replace(f,'''company'',''buyer_discount''','''company'',''buyer_discount'',''network_rewards'',''unallocated''');
  f:=replace(f,'''buyer_discount'',''company''','''buyer_discount'',''company'',''network_rewards'',''unallocated''');execute f;
 end loop;
 f:=pg_get_functiondef('private.credit_single_line(uuid)'::regprocedure);
 f:=replace(f,'round(a.bv*r.depth/300,4)-round(a.bv*(r.depth-1)/300,4)','trunc(least(a.bv,a.base_value,a.payable_price-a.company_fee)*r.depth/300,4)-trunc(least(a.bv,a.base_value,a.payable_price-a.company_fee)*(r.depth-1)/300,4)');execute f;
end $$;

-- Allure formula remains tied to sale price on every edit. Leave approval manual.
create function private.allure_formula() returns trigger language plpgsql security definer set search_path='' as $$ begin
 if exists(select 1 from public.vendors where id=new.vendor_id and is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%') then
  new.ppv_per_unit:=case when new.price_pkr>0 then trunc(new.price_pkr*0.25/300*0.90,4) else null end;
 end if;return new;
end $$;
create trigger zz_allure_formula before insert or update on public.products for each row execute function private.allure_formula();
update public.products set price_pkr=price_pkr where vendor_id in(select id from public.vendors where is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%');
insert into public.audit_logs(action,entity_type,entity_id,after_data)
select 'ALLURE_SALE_FORMULA_SET','vendor',id,jsonb_build_object('company_sale_percent',5,'network_sale_percent',25,'pkr_per_point',300,'ppv_factor',0.90,'rounding','truncate_4','approval','manual') from public.vendors where is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%';

create function public.vendor_company_earnings() returns jsonb language plpgsql stable security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 return coalesce((select jsonb_agg(r) from(select v.id,v.business_name,coalesce(sum(a.amount_pkr),0) company_earnings_pkr from public.vendors v left join public.order_items i on i.vendor_id=v.id left join public.commission_allocations a on a.order_item_id=i.id and a.share_kind='company' group by v.id,v.business_name order by v.business_name)r),'[]');
end $$;
revoke all on function public.set_vendor_sale_distribution(uuid,jsonb),public.vendor_company_earnings() from public,anon;
grant execute on function public.set_vendor_sale_distribution(uuid,jsonb),public.vendor_company_earnings() to authenticated;
revoke all on function private.valid_sale_distribution(jsonb,numeric),private.sale_reward_candidates(uuid,numeric),private.post_shopping_bonus(uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric),private.post_shopping_rewards(uuid),private.post_vendor_sale_legacy(),private.allure_formula() from public,anon,authenticated;
notify pgrst,'reload schema';
-- Shopping point conversion is fixed and independent of Premium currency quotes.
do $$ declare f text; begin
 f:=pg_get_functiondef('private.place_marketplace_order(jsonb,text,text,text,text,text)'::regprocedure);
 f:=replace(f,'  select (config_value->>''usd_to_pkr_rate'')::numeric into rate from public.system_config'||chr(10)||'    where config_key=''CURRENCY'' and effective_to is null order by version desc limit 1;'||chr(10)||'  if rate is null then raise exception ''Marketplace is waiting for the admin to configure the USD/PKR PPV conversion rate''; end if;','  rate:=300; -- Fixed shopping conversion.');execute f;
 f:=pg_get_functiondef('public.company_network_summary()'::regprocedure);
 f:=replace(f,'from public.package_activations where status=''approved''','from public.package_activations where status=''approved'' and source<>''SHOPPING_PPV''');execute f;
 f:=pg_get_functiondef('public.offer_vendor_commission(uuid,numeric,text)'::regprocedure);
 f:=replace(f,'p_rate<0 or','p_rate<0.05 or');execute f;
 f:=pg_get_functiondef('public.admin_review_vendor_application(uuid,boolean,numeric)'::regprocedure);
 f:=replace(f,'p_commission_rate<0 or','p_commission_rate<0.05 or');execute f;
end $$;


-- ===== schema/20261002150000_inactive_package_status.sql =====
alter type public.account_status add value if not exists 'inactive';


-- ===== schema/20261002150001_package_eligibility.sql =====
-- Completed registration is not package activation.
create function private.package_eligible(member uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.member_profiles where user_id=member and status='active') and exists(select 1 from public.package_activations where member_id=member and status='approved');
$$;
create function private.enforce_package_membership() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.sponsor_id is not null and (TG_OP='INSERT' or new.sponsor_id is distinct from old.sponsor_id) then
  if not private.package_eligible(new.sponsor_id) and not exists(select 1 from public.user_roles where user_id=new.sponsor_id and role='admin') then raise exception 'Sponsor must activate a package before building a team'; end if;
 end if;
 if new.status='active' and not exists(select 1 from public.user_roles where user_id=new.user_id and role='admin') and not exists(select 1 from public.package_activations where member_id=new.user_id and status='approved') then new.status:='inactive'; end if;
 return new;
end $$;
create trigger zz_package_membership before insert or update on public.member_profiles for each row execute function private.enforce_package_membership();
create function private.activate_package_member() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' then update public.member_profiles set status='active',updated_at=now() where user_id=new.member_id and status='inactive' and terms_accepted_at is not null; end if;return new;
end $$;
create trigger aa_activate_package_member after insert or update of status on public.package_activations for each row execute function private.activate_package_member();
create function private.enforce_bonus_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.payable_amount>0 and new.status='posted' then
  if not private.package_eligible(new.beneficiary_id) then raise exception 'Inactive member cannot receive incentives'; end if;
  if new.source_order_id is not null then select buyer_id into buyer from public.orders where id=new.source_order_id;
  elsif new.source_activation_id is not null then select member_id into buyer from public.package_activations where id=new.source_activation_id; end if;
  if buyer=new.beneficiary_id then raise exception 'Own purchase gives activation PPV only, not an incentive'; end if;
 end if;return new;
end $$;
create trigger aa_bonus_eligibility before insert on public.bonus_transactions for each row execute function private.enforce_bonus_eligibility();
-- Registered inactive members may buy products or a package; suspended/closed remain blocked.
do $$declare f text; sig text;begin
 foreach sig in array array['public.activate_package_with_mio(text,text)','private.place_marketplace_order(jsonb,text,text,text,text,text)','public.request_offline_premium_purchase(text,text,text)'] loop
  f:=pg_get_functiondef(sig::regprocedure);
  f:=replace(f,'user_id=member and status=''active''','user_id=member and status in (''active'',''inactive'') and terms_accepted_at is not null');
  f:=replace(f,'user_id=buyer and status=''active''','user_id=buyer and status in (''active'',''inactive'') and terms_accepted_at is not null');
  f:=replace(f,'user_id=uid and status=''active''','user_id=uid and status in (''active'',''inactive'') and terms_accepted_at is not null');execute f;
 end loop;
 f:=pg_get_functiondef('private.place_signup_binary()'::regprocedure);f:=replace(f,'new.status=''active''','new.status in (''active'',''inactive'')');execute f;
 -- Funding volumes belong to the sale event, not to the buyer's spendable point balances.
 f:=pg_get_functiondef('private.post_shopping_rewards(uuid)'::regprocedure);
 f:=replace(f,'insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)'||chr(10)||' select buyer,k,case when k in(''BV'',''DP'') then b else trunc(b/2,4) end,oid,''credit'',''shopping:''||oid||'':''||k from unnest(array[''BV'',''DP'',''GP'',''BRP'']) k where case when k in(''BV'',''DP'') then b else trunc(b/2,4) end>0;','-- Sale BV funding is stored in shopping_reward_events; buyer only gets PPV.');execute f;
 -- Allow inactive recipients to receive activation funding, not earned incentives.
 f:=pg_get_functiondef('private.mio_transfer(uuid,numeric,text)'::regprocedure);
 f:=replace(f,'user_id=p_recipient_id and status=''active''','user_id=p_recipient_id and status in (''active'',''inactive'') and terms_accepted_at is not null');execute f;
 f:=pg_get_functiondef('public.lookup_transfer_recipient(text)'::regprocedure);
 f:=replace(f,'and m.status=''active''','and m.status in (''active'',''inactive'') and m.terms_accepted_at is not null');execute f;
end $$;
revoke all on function private.package_eligible(uuid),private.enforce_package_membership(),private.activate_package_member(),private.enforce_bonus_eligibility() from public,anon,authenticated;
create or replace function private.assign_activation_points() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' and new.source<>'SHOPPING_PPV' then perform private.credit_activation_bonuses(new.id); end if;return new;
end $$;
create function private.enforce_commission_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.share_kind in ('affiliate','sponsor','second_upline','introducer') and new.beneficiary_id is not null then
  select o.buyer_id into buyer from public.order_items i join public.orders o on o.id=i.order_id where i.id=new.order_item_id;
  if not private.package_eligible(new.beneficiary_id) or new.beneficiary_id=buyer then
   if new.status='paid' then raise exception 'Inactive member or buyer cannot receive this incentive'; end if;
   new.beneficiary_id:=null;new.status:='held';
  end if;
 end if;return new;
end $$;
create trigger aa_commission_eligibility before insert or update on public.commission_allocations for each row execute function private.enforce_commission_eligibility();
revoke all on function private.enforce_commission_eligibility() from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261002155900_featured_product_bounded_replace.sql =====
do $$declare f text;begin f:=pg_get_functiondef('public.set_featured_products(uuid[])'::regprocedure);f:=replace(f,'delete from public.featured_products;','delete from public.featured_products where position between 1 and 6;');execute f;end $$;


-- ===== schema/20261002180000_tree_visibility.sql =====
create or replace function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); root uuid; is_company boolean; allowed boolean; result jsonb; root_depth integer:=0; view_depth integer; begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status='active') then raise exception 'Active account required'; end if;
 is_company:=private.has_role('admin'); root:=uid;
 if p_kind not in('generation','binary','pool','single_line','vendor') or p_depth is null or p_depth<0 or (not is_company and p_depth not between 1 and 10) then raise exception 'Invalid tree view'; end if;
 view_depth:=case when p_depth=0 then (select count(*)::integer from public.member_profiles) else p_depth end;
 if is_company and p_kind in('binary','pool','single_line') then select founder_id into root from private.network_foundation where company_id=uid; end if;
 if nullif(trim(p_root_code),'') is not null then
  select user_id into root from public.member_profiles where member_code=upper(trim(p_root_code));

 end if;
 if not is_company then
  with recursive team(id,depth,path) as (
   select uid,0,array[uid]
   union all select m.user_id,t.depth+1,t.path||m.user_id from team t join public.member_profiles m on
    (p_kind in('generation','vendor') and m.sponsor_id=t.id) or
    (p_kind not in('generation','vendor') and exists(select 1 from public.binary_placements b where b.member_id=m.user_id and b.parent_id=t.id))
   where t.depth<10 and not m.user_id=any(t.path)
  ) select min(depth) into root_depth from team where id=root;
  if root_depth is null then raise exception 'Your network is limited to 10 levels'; end if;
  view_depth:=least(view_depth,10-root_depth);
 end if;
 if root is null then return jsonb_build_object('nodes','[]'::jsonb); end if;
 if p_kind='vendor' then
  return jsonb_build_object('nodes',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'parent_id',root,'full_name',v.business_name,'member_code',m.member_code,'depth',1,'commission_rate',v.commission_rate,'status',v.status)) from public.vendors v join public.member_profiles m on m.user_id=v.owner_user_id where m.sponsor_id=root),'[]'::jsonb));
 end if;
 with recursive tree(id,parent_id,side,depth,path) as (
  select root,null::uuid,null::text,0,array[root]
  union all select m.user_id, t.id,case when p_kind='generation' then null else b.side end,t.depth+1,t.path||m.user_id from tree t join public.member_profiles m on
   (p_kind='generation' and m.sponsor_id=t.id) or (p_kind<>'generation' and exists(select 1 from public.binary_placements x where x.member_id=m.user_id and x.parent_id=t.id))
   left join public.binary_placements b on b.member_id=m.user_id where t.depth<view_depth and not m.user_id=any(t.path)
 ), bounded as(select * from tree order by depth,id limit 501)
 select jsonb_build_object('root_depth',root_depth,'visible_levels',view_depth,'truncated',count(*)>500,'nodes',coalesce(jsonb_agg(jsonb_build_object('id',t.id,'parent_id',t.parent_id,'side',t.side,'depth',t.depth,'member_code',m.member_code,'full_name',m.full_name,'status',m.status,'package',private.current_package_code(t.id),
 'bp',coalesce((select bp from public.package_activations a where a.member_id=t.id and a.status='approved' order by base_value desc,activated_at desc limit 1),0),
 'left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT'),0)-coalesce((select sum(consumed_left) from public.binary_member_results where member_id=t.id),0),
 'right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT'),0)-coalesce((select sum(consumed_right) from public.binary_member_results where member_id=t.id),0)) order by t.depth,t.side,t.id) filter(where t.id in(select id from bounded limit 500)),'[]'::jsonb)) into result from bounded t join public.member_profiles m on m.user_id=t.id;
 return result;
end $$;


-- ===== schema/20261002210047_configurable_mlm_plans.sql =====
-- Approved simulation defaults; immutable snapshots for future events.
alter table public.orders add column rules_snapshot jsonb not null default '{}'::jsonb;
alter table public.package_activations add column rules_snapshot jsonb not null default '{}'::jsonb, add column binary_reserve_mio numeric(18,4) not null default 0;
update public.package_activations set binary_reserve_mio=trunc(least(bv,base_value,payable_price-company_fee)*.35,4) where status='approved' and source<>'SHOPPING_PPV';
insert into public.system_config(config_key,version,config_value)
select 'MLM_PLANS',1,jsonb_build_object('version',1,'direct_generation_cap',.55,'single_line_cap',.10,'binary_pool_rate',.35,'shopping_ppv_factor',.90,'shopping_bp_factor',.50,'pkr_per_mio',300,'plans',jsonb_object_agg(p.package_code,to_jsonb(p)||jsonb_build_object('generation_rates',(select jsonb_object_agg(n::text,.05) from generate_series(2,p.max_generations)n),'single_line_levels',case p.package_code when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 else 30 end,'single_line_rates',(select jsonb_agg(1::numeric/300) from generate_series(1,case p.package_code when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 else 30 end))))) from public.package_versions p where is_active;
create function private.current_mlm_rules() returns jsonb language sql stable security definer set search_path='' as $$select config_value from public.system_config where config_key='MLM_PLANS' and effective_to is null order by version desc limit 1$$;
create function public.get_plan_catalog() returns jsonb language sql stable security definer set search_path='' as $$select private.current_mlm_rules()$$;
create function private.snapshot_mlm_rules() returns trigger language plpgsql security definer set search_path='' as $$begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(least(new.bv,new.base_value,new.payable_price-new.company_fee)*.35,4) else 0 end;end if;
 return new;
end $$;
create trigger a_snapshot_mlm_rules before insert on public.orders for each row execute function private.snapshot_mlm_rules();
create trigger a_snapshot_mlm_rules before insert on public.package_activations for each row execute function private.snapshot_mlm_rules();
create function public.admin_save_plan(p_code text,p_plan jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;rate numeric;tot numeric;key text;begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;perform private.require_recent_totp();
 perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;
 if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','company_fee','ppv','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','single_line_levels'] loop
  if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;
  rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 or rate<>round(rate,case when key in('direct_rate','binary_entitlement') then 6 when key in('base_value','company_fee') then 2 else 4 end) then raise exception 'Invalid plan value: %',key;end if;
 end loop;
 if (p_plan->>'base_value')::numeric<=0 or (p_plan->>'ppv')::numeric<=0 or (p_plan->>'bv')::numeric>(p_plan->>'base_value')::numeric or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;
 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;
 if levels not between 1 and 10 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–10; single-line limit 1–30';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' or not((p_plan->'generation_rates') ? i::text) then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;end loop;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid single-line rate';end if;tot:=tot+rate;end loop;
 if tot>.100000000001 then raise exception 'Single-line total cannot exceed the funded 10 percent budget';end if;
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement)
 values(p_code,old.version+1,old.display_name,(p_plan->>'base_value')::numeric,(p_plan->>'company_fee')::numeric,(p_plan->>'ppv')::numeric,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels) into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));
 update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan));
 return cfg;
end $$;
-- Inactive registration allows referrals; incentive eligibility is separate.
create function private.registered_member(member uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.member_profiles where user_id=member and status in('active','inactive') and terms_accepted_at is not null)$$;
create or replace function private.enforce_package_membership() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.sponsor_id is not null and (TG_OP='INSERT' or new.sponsor_id is distinct from old.sponsor_id) and not private.registered_member(new.sponsor_id) and not exists(select 1 from public.user_roles where user_id=new.sponsor_id and role='admin') then raise exception 'Registered sponsor required';end if;
 if new.status='active' and not exists(select 1 from public.user_roles where user_id=new.user_id and role='admin') and not exists(select 1 from public.package_activations where member_id=new.user_id and status='approved') then new.status:='inactive';end if;return new;
end $$;
do $$declare f text;sig text;begin
 foreach sig in array array['private.create_member_profile()','private.complete_referral_join(text,text,text,boolean)','public.lookup_side_referral(text)'] loop
 f:=pg_get_functiondef(sig::regprocedure);f:=replace(f,'and status=''active''','and status in(''active'',''inactive'') and terms_accepted_at is not null');f:=replace(f,'and m.status=''active''','and m.status in(''active'',''inactive'') and m.terms_accepted_at is not null');execute f;end loop;
end $$;
create or replace function private.enforce_bonus_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.payable_amount<=0 or new.status='reversed' then return new;end if;
 if new.source_order_id is not null then select buyer_id into buyer from public.orders where id=new.source_order_id;elsif new.source_activation_id is not null then select member_id into buyer from public.package_activations where id=new.source_activation_id;end if;
 if buyer=new.beneficiary_id then raise exception 'Own purchase gives PPV only';end if;
 if not private.package_eligible(new.beneficiary_id) then
 if new.method<>'direct' or not private.registered_member(new.beneficiary_id) or coalesce(new.generation,1)<>1 then raise exception 'Inactive member can earn held direct level only';end if;new.status:='pending';end if;return new;
end $$;
create function private.release_direct_holds() returns trigger language plpgsql security definer set search_path='' as $$declare b record;begin
 if new.status<>'approved' or not private.package_eligible(new.member_id) then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended('release-holds:'||new.member_id::text,0));
 for b in update public.bonus_transactions set status='posted' where beneficiary_id=new.member_id and method='direct' and status='pending' returning * loop
 insert into public.mio_ledger(member_id,amount,action,source_order_id,activation_id,bonus_transaction_id,reason,idempotency_key) values(new.member_id,b.payable_amount,'bonus_credit',b.source_order_id,b.source_activation_id,b.id,'Released held direct earning','bonus:'||b.id) on conflict(idempotency_key) do nothing;
 if found then update public.mio_wallet_accounts set balance=balance+b.payable_amount,updated_at=now() where member_id=new.member_id;end if;
 end loop;return new;
end $$;
create trigger ab_release_direct_holds after insert or update of status on public.package_activations for each row execute function private.release_direct_holds();
create function private.mlm_candidates(member uuid,b numeric,cfg jsonb) returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric) language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)),
 resolved as(select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,private.package_eligible(u.id) eligible from up u where depth>0 and private.registered_member(u.id))
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
 b*case when depth=1 then (cfg->'plans'->case when eligible then coalesce(private.current_package_code(member),'BASIC_1') else 'BASIC_1' end->>'direct_rate')::numeric else coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=(plan->>'max_generations')::integer);
$$;
create function private.post_network_bonus(oid uuid,aid uuid,who uuid,kind public.bonus_method,d integer,b numeric,nominal numeric,amount numeric,cfg jsonb) returns void language plpgsql security definer set search_path='' as $$declare tx uuid;state text;begin
 if amount<=0 then return;end if;
 insert into public.bonus_transactions(beneficiary_id,method,source_order_id,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
 values(who,kind,oid,aid,d,b,case when b>0 then amount/b else 0 end,nominal,amount,'MIO','editable-plans-v1',jsonb_build_object('plan_rules',cfg,'nominal_mio',nominal,'funded_mio',amount,'depth',d),'mlm:'||coalesce(oid,aid)||':'||kind||':'||who||':'||d) on conflict(idempotency_key) do nothing returning id,status into tx,state;
 if tx is not null and state='posted' then
 update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=who;if not found then raise exception 'Recipient wallet missing';end if;
 insert into public.mio_ledger(member_id,amount,action,source_order_id,activation_id,bonus_transaction_id,reason,idempotency_key) values(who,amount,'bonus_credit',oid,aid,tx,'Plan network bonus','bonus:'||tx);
 end if;
end $$;
create function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare total numeric;scale numeric;amount numeric;r record;p uuid;current_member uuid:=member;side text;d integer:=0;plan jsonb;rates jsonb;cum numeric;prev numeric;dg numeric:=0;sl numeric:=0;slscale numeric:=1;begin
 select coalesce(sum(nominal),0) into total from private.mlm_candidates(member,b,cfg);scale:=case when total>0 then least(1,trunc(b*.55,4)/total) else 0 end;
 select coalesce(sum(b*coalesce((cfg->'plans'->private.current_package_code(x.id)->'single_line_rates'->>(x.depth-1))::numeric,0)),0) into total from (
 with recursive chain(id,depth,path) as(select p.parent_id,1,array[member,p.parent_id] from public.binary_placements p where p.member_id=member and p.parent_id is not null union all select p.parent_id,c.depth+1,c.path||p.parent_id from chain c join public.binary_placements p on p.member_id=c.id where p.parent_id is not null and c.depth<1000 and not p.parent_id=any(c.path)) select * from chain
 )x where private.package_eligible(x.id) and x.depth<=coalesce((cfg->'plans'->private.current_package_code(x.id)->>'single_line_levels')::integer,0);
 slscale:=case when total>0 then least(1,trunc(b*.10,4)/total) else 0 end;
 for r in select * from private.mlm_candidates(member,b,cfg) order by depth loop
 amount:=trunc(r.nominal*scale,4);perform private.post_network_bonus(oid,aid,r.beneficiary,r.method,r.depth,b,r.nominal,amount,cfg);dg:=dg+amount;end loop;
 loop
 select bp.parent_id,bp.side into p,side from public.binary_placements bp where bp.member_id=current_member;exit when p is null;d:=d+1;if d>1000 then raise exception 'Placement ancestry exceeds supported depth';end if;
 if oid is not null and trunc(b*.5,4)>0 then insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(b*.5,4),side,oid,'credit','shopping-bp:'||oid||':'||p) on conflict(idempotency_key) do nothing;end if;
 plan:=cfg->'plans'->private.current_package_code(p);
 if private.package_eligible(p) and d<=coalesce((plan->>'single_line_levels')::integer,0) then
 rates:=plan->'single_line_rates';select coalesce(sum(value::numeric),0) into cum from jsonb_array_elements_text(rates) with ordinality where ordinality<=d;select coalesce(sum(value::numeric),0) into prev from jsonb_array_elements_text(rates) with ordinality where ordinality<d;
 amount:=case when slscale=1 then trunc(round(b*cum,12),4)-trunc(round(b*prev,12),4) else trunc(b*coalesce((rates->>(d-1))::numeric,0)*slscale,4) end;amount:=least(amount,greatest(0,trunc(b*.10,4)-sl));perform private.post_network_bonus(oid,aid,p,'single_line',d,b,b*coalesce((rates->>(d-1))::numeric,0),amount,cfg);sl:=sl+amount;end if;
 current_member:=p;
 end loop;return jsonb_build_object('direct_generation',dg,'single_line',sl);
end $$;
-- Keep legacy branches for pre-migration snapshots; new events use configured levels.
alter function private.credit_activation_bonuses(uuid) rename to credit_activation_bonuses_legacy;
create function private.credit_activation_bonuses(p_activation_id uuid) returns integer language plpgsql security definer set search_path='' as $$declare a public.package_activations%rowtype;r jsonb;begin
 select * into a from public.package_activations where id=p_activation_id;if a.id is null or a.status<>'approved' or a.source='SHOPPING_PPV' then return 0;end if;
 if a.rules_snapshot='{}'::jsonb then return private.credit_activation_bonuses_legacy(p_activation_id);end if;
 if exists(select 1 from public.bonus_transactions where source_activation_id=a.id and formula_version<>'editable-plans-v1') then return 0;end if;
 r:=private.distribute_mlm_event(a.member_id,least(a.bv,a.base_value,a.payable_price-a.company_fee),null,a.id,a.rules_snapshot);return 1;
end $$;
alter function private.credit_single_line(uuid) rename to credit_single_line_legacy;
create function private.credit_single_line(p_activation uuid) returns void language plpgsql security definer set search_path='' as $$declare a public.package_activations%rowtype;begin
 select * into a from public.package_activations where id=p_activation;
 if a.rules_snapshot='{}'::jsonb then perform private.credit_single_line_legacy(p_activation);end if;
 -- New activation's combined engine has already posted single-line exactly once.
end $$;
alter function private.post_shopping_rewards(uuid) rename to post_shopping_rewards_legacy;
create function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$declare buyer uuid;cfg jsonb;funding numeric;b numeric;r jsonb;begin
 select buyer_id,rules_snapshot into buyer,cfg from public.orders where id=oid and payment_status='confirmed';if buyer is null then return;end if;
 if cfg='{}'::jsonb then perform private.post_shopping_rewards_legacy(oid);return;end if;
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=oid and a.share_kind='network_rewards';
 select coalesce(sum(trunc(i.ppv_per_unit_snapshot*i.quantity,4)),0) into b from public.order_items i where order_id=oid;
 if b<=0 then return;end if;
 if b*300>funding then raise exception 'Shopping PPV/BV exceeds verified network funding';end if;
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(oid,buyer,funding,b,trunc(b*.35,4)) on conflict do nothing;if not found then return;end if;
 r:=private.distribute_mlm_event(buyer,b,oid,null,cfg);
 update public.shopping_reward_events set direct_generation_mio=(r->>'direct_generation')::numeric,single_line_mio=(r->>'single_line')::numeric where order_id=oid;
end $$;
-- Held bonuses reserve funding, but do not enter an inactive spendable wallet.
do $$declare f text;begin f:=pg_get_functiondef('private.guard_bonus_funding()'::regprocedure);f:=replace(f,'status=''posted''','status in(''posted'',''pending'')');execute f;end $$;
-- Referral-linked purchases use the purchaser's permanent sponsor; no separate affiliate payout.
create or replace function private.guard_company_commission() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.is_company_owned and coalesce(new.commission_rate,0)=0 then new.commission_rate:=.05;end if;
 if new.commission_rate>=.05 then new.sale_distribution:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',new.commission_rate*100-5,'unallocated',0);end if;return new;
end $$;
update public.vendors set sale_distribution=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',commission_rate*100-5,'unallocated',0) where commission_rate>=.05;
create or replace function public.set_vendor_sale_distribution(p_vendor_id uuid,p_split jsonb) returns void language plpgsql security definer set search_path='' as $$begin raise exception 'Separate ecommerce percentage editor is on hold. Use Edit Plans';end $$;
-- PPV is derived by the formula trigger; manual submitted PPV cannot override it.
create or replace function private.guard_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin return new;end $$;
-- Price/commission-derived PPV remains visible before checkout and is saved on each item.
create function private.formula_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$declare rate numeric;begin
 select commission_rate into rate from public.vendors where id=new.vendor_id;
 new.ppv_per_unit:=trunc(new.price_pkr*greatest(coalesce(rate,0)-.05,0)*.90/300,4);return new;
end $$;
create trigger zz_formula_product_ppv before insert or update on public.products for each row execute function private.formula_product_ppv();
update public.products p set ppv_per_unit=trunc(p.price_pkr*greatest(v.commission_rate-.05,0)*.90/300,4) from public.vendors v where v.id=p.vendor_id;
create function private.refresh_vendor_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin if new.commission_rate is distinct from old.commission_rate then update public.products set updated_at=now() where vendor_id=new.id;end if;return new;end $$;
create trigger refresh_vendor_ppv after update of commission_rate on public.vendors for each row execute function private.refresh_vendor_ppv();
-- Read-only alias snapshot no longer demands an active separate selling affiliate.
create or replace function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$declare v public.vendors%rowtype;begin
 select * into v from public.vendors where id=new.vendor_id;
 if v.commission_rate<.05 then raise exception 'Vendor commission must cover company 5 percent';end if;
 new.commission_rate_snapshot:=v.commission_rate;new.company_owned_snapshot:=v.is_company_owned;new.commission_split_snapshot:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',v.commission_rate*100-5,'unallocated',0);new.distribution_basis:='sale_v2';
 new.commission_pool_pkr:=round(new.unit_price_pkr*new.quantity*v.commission_rate,2);new.buyer_discount_pkr:=0;return new;
end $$;
create or replace function private.snapshot_item_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 new.ppv_per_unit_snapshot:=trunc(new.unit_price_pkr*greatest(new.commission_rate_snapshot-.05,0)*.90/300,4);return new;
end $$;
-- Current settings determine entitlement at cycle close; immutable result snapshots keep history.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_close_binary_cycle(text,timestamptz,timestamptz,text)'::regprocedure);
 f:=replace(f,'pool:=trunc(eligible*0.35,4)','pool:=(select coalesce(sum(binary_reserve_mio),0) from public.package_activations where status=''approved'' and source<>''SHOPPING_PPV'' and activated_at>=p_starts_at and activated_at<p_ends_at)');
 f:=replace(f,'a.package_version,a.binary_entitlement','a.package_version,coalesce((private.current_mlm_rules()->''plans''->a.package_code->>''binary_entitlement'')::numeric,a.binary_entitlement) binary_entitlement');execute f;
end $$;
create function public.my_reward_holds() returns jsonb language plpgsql security definer set search_path='' as $$declare uid uuid:=auth.uid();begin
 if uid is null then raise exception 'Sign in required';end if;return jsonb_build_object('direct_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=uid and status='pending'),0),'withdrawal_unlocked',private.package_eligible(uid));end $$;
revoke all on function private.current_mlm_rules(),private.snapshot_mlm_rules(),private.registered_member(uuid),private.release_direct_holds(),private.mlm_candidates(uuid,numeric,jsonb),private.post_network_bonus(uuid,uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric,jsonb),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb),private.credit_activation_bonuses_legacy(uuid),private.credit_activation_bonuses(uuid),private.credit_single_line_legacy(uuid),private.credit_single_line(uuid),private.post_shopping_rewards_legacy(uuid),private.post_shopping_rewards(uuid),private.formula_product_ppv(),private.refresh_vendor_ppv() from public,anon,authenticated;
revoke all on function public.admin_save_plan(text,jsonb,integer),public.my_reward_holds() from public,anon;grant execute on function public.admin_save_plan(text,jsonb,integer),public.my_reward_holds() to authenticated;
revoke all on function public.get_plan_catalog() from public;grant execute on function public.get_plan_catalog() to anon,authenticated;
notify pgrst,'reload schema';
-- Free registered members can inspect their referral tree while earnings remain held.
do $$declare f text;begin f:=pg_get_functiondef('public.my_network(text,text,integer)'::regprocedure);f:=replace(f,'user_id=uid and status=''active''','user_id=uid and status in(''active'',''inactive'') and terms_accepted_at is not null');execute f;end $$;


-- ===== schema/20261002210542_company_treasury_dashboard.sql =====
-- Company account accounting is separate from mintable operational MIO balances.
create table public.company_treasury_positions(source_type text not null,source_id uuid not null,category text not null,currency text not null check(currency in('PKR','MIO')),amount numeric(20,4) not null check(amount>=0),updated_at timestamptz not null default now(),primary key(source_type,source_id,category,currency));
create table public.company_treasury_ledger(id bigint generated always as identity primary key,company_id uuid not null references public.member_profiles(user_id),source_type text not null,source_id uuid not null,category text not null,currency text not null check(currency in('PKR','MIO')),amount numeric(20,4) not null check(amount<>0),created_at timestamptz not null default now());
alter table public.company_treasury_positions enable row level security;alter table public.company_treasury_ledger enable row level security;
create policy company_positions_admin on public.company_treasury_positions for select to authenticated using(private.has_role('admin'));
create policy company_ledger_admin on public.company_treasury_ledger for select to authenticated using(private.has_role('admin'));
revoke all on public.company_treasury_positions,public.company_treasury_ledger from public,anon,authenticated;grant select on public.company_treasury_positions,public.company_treasury_ledger to authenticated;
create function private.company_treasury_sources() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 with funding as(
 select 'order'::text typ,s.order_id id,s.bv base,s.binary_reserve_mio reserve from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.binary_reserve_mio from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ), spend as(select f.*,coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status in('posted','pending') and ((f.typ='order' and b.source_order_id=f.id) or (f.typ='package' and b.source_activation_id=f.id)) and b.method in('direct','generation')),0) dg,coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status in('posted','pending') and ((f.typ='order' and b.source_order_id=f.id) or (f.typ='package' and b.source_activation_id=f.id)) and b.method='single_line'),0) sl from funding f)
 select typ,id,'direct_generation_leftover','MIO',greatest(0,trunc(base*.55,4)-dg) from spend
 union all select typ,id,'single_line_leftover','MIO',greatest(0,trunc(base*.10,4)-sl) from spend
 union all select typ,id,'network_rounding_leftover','MIO',greatest(0,base-trunc(base*.55,4)-trunc(base*.10,4)-reserve) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*300) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$$;
create function private.sync_company_treasury() returns void language plpgsql security definer set search_path='' as $$declare company uuid;r record;delta numeric;begin
 select company_id into company from private.network_foundation where singleton; if company is null then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('company-treasury-sync',0));
 for r in with expected as(select source_type,source_id,category,currency,sum(amount) amount from private.company_treasury_sources() group by 1,2,3,4) select coalesce(e.source_type,p.source_type) typ,coalesce(e.source_id,p.source_id) sid,coalesce(e.category,p.category) cat,coalesce(e.currency,p.currency) cur,coalesce(e.amount,0) target,coalesce(p.amount,0) previous from expected e full join public.company_treasury_positions p using(source_type,source_id,category,currency) loop
  delta:=r.target-r.previous;if delta=0 then continue;end if;
  insert into public.company_treasury_positions(source_type,source_id,category,currency,amount) values(r.typ,r.sid,r.cat,r.cur,r.target) on conflict(source_type,source_id,category,currency) do update set amount=excluded.amount,updated_at=now();
  insert into public.company_treasury_ledger(company_id,source_type,source_id,category,currency,amount) values(company,r.typ,r.sid,r.cat,r.cur,delta);
 end loop;
end $$;
create function private.company_treasury_event() returns trigger language plpgsql security definer set search_path='' as $$begin perform private.sync_company_treasury();return null;end $$;
create trigger zz_company_order_account after update of payment_status on public.orders for each statement execute function private.company_treasury_event();
create trigger zz_company_package_account after insert or update on public.package_activations for each statement execute function private.company_treasury_event();
create trigger zz_company_bonus_account after insert or update on public.bonus_transactions for each statement execute function private.company_treasury_event();
create trigger zz_company_cycle_account after insert or update on public.binary_cycles for each statement execute function private.company_treasury_event();
create trigger zz_company_commission_account after insert or update on public.commission_allocations for each statement execute function private.company_treasury_event();
create function public.company_master_dashboard() returns jsonb language plpgsql security definer set search_path='' as $$declare result jsonb;begin
 if not private.has_role('admin') then raise exception 'Master account access required';end if;
 perform private.sync_company_treasury();
 select jsonb_build_object(
 'company',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.company_id),
 'founder',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.founder_id),
 'sales_pkr',coalesce((select sum(subtotal_pkr) from public.orders where payment_status='confirmed'),0),
 'shipping_pkr',coalesce((select sum(delivery_fee_pkr) from public.orders where payment_status='confirmed'),0),
 'verified_package_receipts_pkr',coalesce((select sum(expected_pkr) from public.premium_purchase_requests where status='approved'),0),
 'package_volume_mio',coalesce((select sum(payable_price) from public.package_activations where status='approved' and source<>'SHOPPING_PPV'),0),
 'credited_network_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where status='posted'),0),
 'held_network_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where status='pending'),0),
 'member_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind in('affiliate','sponsor','second_upline','introducer') and status in('earned','paid') and beneficiary_id is not null),0),
 'paid_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind in('affiliate','sponsor','second_upline','introducer') and status='paid'),0),
 'held_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind in('affiliate','sponsor','second_upline','introducer') and status='held'),0),
 'external_vendor_proceeds_pkr',coalesce((select sum(l.net_pkr) from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id where not i.company_owned_snapshot),0),
 'vendor_withdrawals_paid_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where status='paid'),0),
 'vendor_withdrawals_reserved_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where status in('pending','approved')),0),
 'binary_reserved_mio',coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events),0)+coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV'),0)-coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated')),0),
 'company_network_mio',coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status='posted' and b.beneficiary_id=(select company_id from private.network_foundation where singleton)),0),
 'company_bonus_sources',coalesce((select jsonb_agg(r) from(select m.full_name,m.member_code,b.method,b.payable_amount amount from public.bonus_transactions b left join public.package_activations a on a.id=b.source_activation_id left join public.orders o on o.id=b.source_order_id join public.member_profiles m on m.user_id=coalesce(a.member_id,o.buyer_id) where b.status='posted' and b.beneficiary_id=(select company_id from private.network_foundation where singleton) order by b.created_at desc limit 30)r),'[]'),
 'company_pkr',coalesce((select sum(amount) from public.company_treasury_positions where currency='PKR'),0),
 'company_mio',coalesce((select sum(amount) from public.company_treasury_positions where currency='MIO'),0),
 'company_sources',coalesce((select jsonb_agg(r) from(select category,currency,sum(amount) amount from public.company_treasury_positions group by 1,2 order by 1,2)r),'[]'),
 'distributed_sources',coalesce((select jsonb_agg(r) from(select method,sum(payable_amount) amount from public.bonus_transactions where status='posted' group by method order by method)r),'[]'),
 'top_network',coalesce((select jsonb_agg(r) from(select m.member_code,m.full_name,sum(b.payable_amount) income from public.bonus_transactions b join public.member_profiles m on m.user_id=b.beneficiary_id where b.status='posted' and m.user_id<>(select company_id from private.network_foundation where singleton) group by m.user_id order by sum(b.payable_amount) desc,m.member_code limit 10)r),'[]'),
 'top_ecommerce',coalesce((select jsonb_agg(r) from(select m.member_code,m.full_name,sum(a.amount_pkr) income from public.commission_allocations a join public.member_profiles m on m.user_id=a.beneficiary_id where a.share_kind in('affiliate','sponsor','second_upline','introducer') and a.status in('earned','paid') group by m.user_id order by sum(a.amount_pkr) desc,m.member_code limit 10)r),'[]')
 ) into result;
 return result;
end $$;
revoke all on function private.company_treasury_sources(),private.sync_company_treasury(),private.company_treasury_event() from public,anon,authenticated;
revoke all on function public.company_master_dashboard() from public,anon;grant execute on function public.company_master_dashboard() to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261002211608_reconcile_existing_members.sql =====
-- Paid package points are chart allocations, not additional cash incentives.
-- Shopping activation has no fresh paid funding and therefore creates no synthetic points.
create function private.credit_paid_package_points(aid uuid) returns void language plpgsql security definer set search_path='' as $$begin
 insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
 select a.member_id,k.kind,k.amount,a.id,'credit','activation:'||a.id||':'||k.kind
 from public.package_activations a cross join lateral(values('BV',a.bv),('DP',a.dp),('GP',a.gp),('BRP',a.brp))k(kind,amount)
 where a.id=aid and a.status='approved' and a.source<>'SHOPPING_PPV' and k.amount>0
 and not exists(select 1 from public.point_ledger p where p.member_id=a.member_id and p.point_type=k.kind and p.source_activation_id=a.id and p.entry_kind='credit') on conflict do nothing;
end $$;
create or replace function private.assign_activation_points() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' and new.source<>'SHOPPING_PPV' then perform private.credit_paid_package_points(new.id);perform private.credit_activation_bonuses(new.id);end if;return new;
end $$;
revoke all on function private.credit_paid_package_points(uuid) from public,anon,authenticated;
-- Existing member IDs, package debits and point history remain intact.
-- Attach the approved rules to old events and award only entirely missing distributions.
do $$declare a record;cfg jsonb:=private.current_mlm_rules();posted integer:=0;preserved integer:=0;begin
 update public.package_activations set rules_snapshot=cfg where rules_snapshot='{}'::jsonb;
 update public.orders set rules_snapshot=cfg where rules_snapshot='{}'::jsonb;
 for a in select * from public.package_activations where status='approved' and source<>'SHOPPING_PPV' order by activated_at,id loop
  perform private.credit_paid_package_points(a.id);
  perform private.credit_binary_volume(a.id);
  if exists(select 1 from public.bonus_transactions where source_activation_id=a.id) then preserved:=preserved+1;continue;end if;
  perform private.credit_activation_bonuses(a.id);posted:=posted+1;
 end loop;
 perform private.sync_company_treasury();
 insert into public.audit_logs(action,entity_type,after_data) values('EXISTING_PLAN_RULES_RECONCILED','package',jsonb_build_object('rules_version',cfg->>'version','missing_sources_processed',posted,'previously_distributed_sources_preserved',preserved,'wallet_debits_repeated',false,'existing_points_repeated',false,'missing_chart_points_backfilled',true));
end $$;
notify pgrst,'reload schema';


-- ===== schema/20261002212815_plan_ppv_bv_validation.sql =====
-- Preserve the approved invariant for all editable package configurations.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_save_plan(text,jsonb,integer)'::regprocedure);
 f:=replace(f,'levels:=(p_plan->>''max_generations'')::integer;', 'if (p_plan->>''bv'')::numeric>(p_plan->>''ppv'')::numeric then raise exception ''BV cannot exceed PPV'';end if; levels:=(p_plan->>''max_generations'')::integer;');
 execute f;
end $$;
notify pgrst,'reload schema';


-- ===== schema/20261002221000_order_delivery_rewards.sql =====
-- Delivery and verified payment jointly release personal and network rewards.
alter table public.orders add column rewards_credited_at timestamptz;
update public.orders set rewards_credited_at=updated_at where ppv_generated>0;
alter function private.post_shopping_rewards(uuid) rename to post_shopping_rewards_delivered;
create function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.orders where id=oid and status='delivered' and payment_status='confirmed') then perform private.post_shopping_rewards_delivered(oid);end if;
end $$;
create function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;ppv numeric;total numeric;begin
 select * into o from public.orders where id=new.id for update;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.buyer_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 perform private.post_shopping_rewards(o.id);
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;
 select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.buyer_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.buyer_id,o.id,total);
 return new;
end $$;
-- Alphabetical trigger ordering ensures vendor funding is reserved before reward release.
create trigger zz_release_order_rewards after update of status,payment_status on public.orders for each row execute function private.release_order_rewards();
create or replace function public.admin_confirm_order_payment(p_order_id uuid) returns numeric language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null then raise exception 'Order not found';end if;
 if o.payment_status='confirmed' then return o.ppv_generated;end if;
 if o.payment_status<>'unconfirmed' or o.status in ('cancelled','returned') then raise exception 'Order is not eligible for payment confirmation';end if;
 update public.orders set payment_status='confirmed',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'ORDER_PAYMENT_CONFIRMED','order',o.id,jsonb_build_object('buyer_id',o.buyer_id,'delivery_status',o.status));
 return (select ppv_generated from public.orders where id=o.id);
end $$;
revoke all on function private.post_shopping_rewards_delivered(uuid),private.post_shopping_rewards(uuid),private.release_order_rewards() from public,anon,authenticated;


-- ===== schema/20261006181511_ecommerce_reward_modes.sql =====
-- New orders choose one funded rewards route. Existing orders retain their snapshot.
alter table public.member_profiles add column shopping_reward_mode text not null default 'PPV' check(shopping_reward_mode in('PPV','MIO'));
alter table public.member_profiles add column achieved_rank text check(achieved_rank in('leader','team_manager','team_leader','senior_team_leader'));
alter table public.orders add column reward_version integer not null default 1;
alter table public.orders alter column reward_version set default 2;
alter table public.orders add column reward_mode text not null default 'PPV' check(reward_mode in('PPV','MIO'));
alter table public.orders add column reward_owner_id uuid references public.member_profiles(user_id);
alter table public.orders add column selling_affiliate_id uuid references public.member_profiles(user_id);
alter table public.orders add column reward_sponsor_id uuid references public.member_profiles(user_id);
alter table public.orders add column reward_second_sponsor_id uuid references public.member_profiles(user_id);
alter table public.orders add column reward_ppv_total numeric(18,4) not null default 0;
create function public.set_shopping_reward_mode(p_mode text) returns void language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or not private.package_eligible(auth.uid()) then raise exception 'Activate any package to choose MIO rewards';end if;
 if p_mode is null or p_mode not in('PPV','MIO') then raise exception 'Choose PPV or MIO';end if;
 update public.member_profiles set shopping_reward_mode=p_mode where user_id=auth.uid();
end $$;
create function private.snapshot_order_reward_mode() returns trigger language plpgsql security definer set search_path='' as $$declare code text:=upper(trim(coalesce(current_setting('mio.affiliate_code',true),'')));seller uuid;begin
 if code<>'' then
 select user_id into seller from public.member_profiles where (upper(member_code)=code or upper(replace(member_code,'MIO-',''))=code or upper(referral_code)=regexp_replace(code,'-[LR]$','')) and status in('active','inactive') and terms_accepted_at is not null;
 if seller is null then raise exception 'Selling link is no longer valid';end if;
 end if;
 if seller=new.buyer_id then seller:=null;end if;
 new.selling_affiliate_id:=seller;new.reward_owner_id:=coalesce(seller,new.buyer_id);
 select case when private.package_eligible(user_id) then shopping_reward_mode else 'PPV' end,sponsor_id into new.reward_mode,new.reward_sponsor_id from public.member_profiles where user_id=new.reward_owner_id;
 select sponsor_id into new.reward_second_sponsor_id from public.member_profiles where user_id=new.reward_sponsor_id;
 new.reward_mode:=coalesce(new.reward_mode,'PPV');return new;
end $$;
create trigger snapshot_order_reward_mode before insert on public.orders for each row execute function private.snapshot_order_reward_mode();
-- Keep the agreed commission and PPV calculation, and save vendor attribution.
do $$declare f text;begin f:=pg_get_functiondef('private.snapshot_commission()'::regprocedure);f:=replace(f,'new.buyer_discount_pkr:=0;return new;','new.buyer_discount_pkr:=0;new.introducer_id_snapshot:=v.introduced_by;return new;');execute f;end $$;
create table public.ecommerce_rewards(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders(id),order_item_id uuid not null references public.order_items(id),
 beneficiary_id uuid references public.member_profiles(user_id),reward_kind text not null check(reward_kind in('cashback','affiliate','sponsor','second_sponsor','vendor_introducer')),
 rate numeric not null,base_points numeric(18,4) not null,amount numeric(18,4) not null check(amount>=0),
 status text not null default 'pending_delivery' check(status in('pending_delivery','held_activation','posted','company_leftover','cancelled')),
 created_at timestamptz not null default now(),credited_at timestamptz,unique(order_item_id,reward_kind));
create index ecommerce_rewards_beneficiary on public.ecommerce_rewards(beneficiary_id,status);
alter table public.ecommerce_rewards enable row level security;
revoke all on public.ecommerce_rewards from public,anon,authenticated;grant select on public.ecommerce_rewards to authenticated;
create policy ecommerce_read on public.ecommerce_rewards for select to authenticated using(beneficiary_id=auth.uid() or private.has_role('admin'));
create function private.prepare_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;b numeric;prev numeric:=0;cum numeric:=0;r record;amt numeric;begin
 select * into o from public.orders where id=new.order_id;
 if o.reward_version<>2 then return new;end if;
 b:=trunc(new.ppv_per_unit_snapshot*new.quantity,4);
 update public.orders set reward_ppv_total=reward_ppv_total+b where id=o.id;
 if o.reward_mode='MIO' and b>0 then
 for r in select * from (values
 (1,case when o.selling_affiliate_id is null then 'cashback' else 'affiliate' end,o.reward_owner_id,.65::numeric),
 (2,'sponsor',o.reward_sponsor_id,.15::numeric),(3,'second_sponsor',o.reward_second_sponsor_id,.075::numeric),(4,'vendor_introducer',new.introducer_id_snapshot,.125::numeric)) x(seq,kind,who,rate) order by seq loop
 cum:=cum+r.rate;amt:=trunc(b*cum,4)-prev;prev:=prev+amt;
 insert into public.ecommerce_rewards(order_id,order_item_id,beneficiary_id,reward_kind,rate,base_points,amount) values(o.id,new.id,r.who,r.kind,r.rate,b,amt);
 end loop;end if;return new;
end $$;
create trigger prepare_order_rewards after insert on public.order_items for each row execute function private.prepare_order_rewards();
create function private.credit_ecommerce_reward(rid uuid) returns void language plpgsql security definer set search_path='' as $$declare r public.ecommerce_rewards%rowtype;begin
 select * into r from public.ecommerce_rewards where id=rid for update;
 if r.status not in('pending_delivery','held_activation') then return;end if;
 if not exists(select 1 from public.orders where id=r.order_id and status='delivered' and payment_status='confirmed') then return;end if;
 if r.beneficiary_id is null then update public.ecommerce_rewards set status='company_leftover' where id=rid;return;end if;
 if not private.package_eligible(r.beneficiary_id) then update public.ecommerce_rewards set status='held_activation' where id=rid;return;end if;
 if r.amount>0 then
 insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key) values(r.beneficiary_id,r.amount,'bonus_credit',r.order_id,'E-commerce '||r.reward_kind,'ecommerce:'||r.id) on conflict(idempotency_key) do nothing;
 if found then update public.mio_wallet_accounts set balance=balance+r.amount,updated_at=now() where member_id=r.beneficiary_id;if not found then raise exception 'Recipient wallet missing';end if;end if;
 end if;
 update public.ecommerce_rewards set status='posted',credited_at=now() where id=rid;
end $$;
create function private.release_ecommerce_holds() returns trigger language plpgsql security definer set search_path='' as $$declare r record;begin
 if new.status='approved' and private.package_eligible(new.member_id) then for r in select id from public.ecommerce_rewards where beneficiary_id=new.member_id and status='held_activation' order by id loop perform private.credit_ecommerce_reward(r.id);end loop;end if;return new;
end $$;
create trigger ac_release_ecommerce_holds after insert or update of status on public.package_activations for each row execute function private.release_ecommerce_holds();
-- Version 1 remains unchanged. Version 2 personal PPV follows the seller on attributed sales.
create or replace function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.orders where id=oid and reward_version=1 and status='delivered' and payment_status='confirmed') then perform private.post_shopping_rewards_delivered(oid);end if;
end $$;
create or replace function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;ppv numeric;total numeric;funding numeric;r record;outcome jsonb;begin
 select * into o from public.orders where id=new.id for update;
 if o.status in('cancelled','returned') and o.rewards_credited_at is null then update public.ecommerce_rewards set status='cancelled' where order_id=o.id and status='pending_delivery';return new;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if o.reward_version=1 then o.reward_owner_id:=o.buyer_id;perform private.post_shopping_rewards(o.id);
 else
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards';
 if ppv*300>funding then raise exception 'Order rewards exceed verified funding';end if;
 if o.reward_mode='MIO' then
 for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop perform private.credit_ecommerce_reward(r.id);end loop;
 update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;
 elsif ppv>0 then
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(o.id,o.reward_owner_id,funding,ppv,trunc(ppv*.35,4)) on conflict do nothing;
 if found then outcome:=private.distribute_mlm_event(o.reward_owner_id,ppv,o.id,null,o.rules_snapshot);
 update public.shopping_reward_events set direct_generation_mio=(outcome->>'direct_generation')::numeric,single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;end if;
 end if;end if;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;
 select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.reward_owner_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);perform private.sync_company_treasury();return new;
end $$;
alter function private.company_treasury_sources() rename to company_treasury_sources_before_ecommerce;
create function private.company_treasury_sources() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 select * from private.company_treasury_sources_before_ecommerce()
 union all select 'ecommerce',id,'ecommerce_missing_recipient','MIO',amount from public.ecommerce_rewards where status='company_leftover'
 union all select 'order',o.id,'ecommerce_conversion_leftover','PKR',greatest(0,(select coalesce(sum(a.amount_pkr),0) from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards')-o.reward_ppv_total*300) from public.orders o where o.reward_version=2 and o.reward_mode='MIO' and o.rewards_credited_at is not null;
$$;
create trigger zz_ecommerce_treasury after update on public.ecommerce_rewards for each statement execute function private.company_treasury_event();
create function public.ecommerce_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$declare uid uuid:=auth.uid();adm boolean:=private.has_role('admin');begin
 if uid is null then raise exception 'Sign in first';end if;
 return jsonb_build_object('mode',(select shopping_reward_mode from public.member_profiles where user_id=uid),'eligible',private.package_eligible(uid),
 'totals',coalesce((select jsonb_agg(x) from(select reward_kind,status,sum(amount) amount from public.ecommerce_rewards where beneficiary_id=uid or adm group by 1,2)x),'[]'),
 'rows',coalesce((select jsonb_agg(x) from(select e.*,o.order_code,m.full_name,m.member_code,src.full_name source_name,src.member_code source_code,i.product_name_snapshot from public.ecommerce_rewards e join public.orders o on o.id=e.order_id join public.order_items i on i.id=e.order_item_id left join public.member_profiles m on m.user_id=e.beneficiary_id left join public.member_profiles src on src.user_id=o.reward_owner_id where e.beneficiary_id=uid or adm order by e.created_at desc,e.id limit 200)x),'[]'),
 'ppv_orders',coalesce((select jsonb_agg(x) from(select o.id,o.order_code,o.status,o.payment_status,o.reward_ppv_total,o.ppv_generated,o.rewards_credited_at,o.selling_affiliate_id from public.orders o where reward_owner_id=uid and reward_mode='PPV' order by created_at desc limit 100)x),'[]'),
 'top_earners',case when adm then coalesce((select jsonb_agg(x) from(select m.full_name,m.member_code,sum(e.amount) income from public.ecommerce_rewards e join public.member_profiles m on m.user_id=e.beneficiary_id where e.status='posted' group by m.user_id order by sum(e.amount) desc limit 10)x),'[]') else '[]'::jsonb end);
end $$;
create function public.admin_set_member_rank(p_code text,p_rank text) returns void language plpgsql security definer set search_path='' as $$declare target uuid;begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 select user_id into target from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_code)),'^MIO-','');
 if target is null then raise exception 'Member not found';end if;
 update public.member_profiles set achieved_rank=nullif(p_rank,'') where user_id=target;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'MEMBER_RANK_SET','member',target,jsonb_build_object('rank',p_rank));
end $$;
-- Names are presentation metadata; package codes and financial history remain stable.
update public.system_config set config_value=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(config_value,'{plans,BASIC_1,display_name}','"Basic"'),'{plans,BASIC_2,display_name}','"Brown"'),'{plans,ADVANCED_1,display_name}','"Silver"'),'{plans,ADVANCED_2,display_name}','"Gold"'),'{plans,PREMIUM,display_name}','"Platinum"') where config_key='MLM_PLANS' and effective_to is null;
revoke all on function public.set_shopping_reward_mode(text),public.ecommerce_dashboard(),public.admin_set_member_rank(text,text) from public,anon;
grant execute on function public.set_shopping_reward_mode(text),public.ecommerce_dashboard(),public.admin_set_member_rank(text,text) to authenticated;
revoke all on function private.snapshot_order_reward_mode(),private.prepare_order_rewards(),private.credit_ecommerce_reward(uuid),private.release_ecommerce_holds(),private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
notify pgrst,'reload schema';

-- Preserve existing tree scope checks; vendor attribution uses the actual introducer.
do $$declare f text;begin
 f:=pg_get_functiondef('public.my_network(text,text,integer)'::regprocedure);
 f:=replace(f,'where member_code=upper(trim(p_root_code))','where member_code=''MIO-''||regexp_replace(upper(trim(p_root_code)),''^MIO-'','''')');
 f:=replace(f,'where m.sponsor_id=root','where v.introduced_by=root');
 f:=replace(f,'''commission_rate'',v.commission_rate','''commission_rate'',v.commission_rate,''node_type'',''vendor''');
 f:=replace(f,'''package'',private.current_package_code(t.id),','''package'',private.current_package_code(t.id),''rank'',m.achieved_rank,''joined_at'',m.created_at,');
 execute f;
end $$;
alter function public.my_network(text,text,integer) rename to my_network_before_vendor_root;
create function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$declare result jsonb;root uuid;parent jsonb;begin
 result:=public.my_network_before_vendor_root(p_kind,p_root_code,p_depth);
 if p_kind='vendor' then
 root:=auth.uid();if nullif(trim(p_root_code),'') is not null then select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');end if;
 select jsonb_build_object('id',user_id,'parent_id',null,'full_name',full_name,'member_code',member_code,'depth',0,'package',private.current_package_code(user_id),'rank',achieved_rank,'status',status) into parent from public.member_profiles where user_id=root;
 result:=jsonb_set(result,'{nodes}',jsonb_build_array(parent)||coalesce(result->'nodes','[]'::jsonb));
 end if;return result;
end $$;
revoke all on function public.my_network_before_vendor_root(text,text,integer) from public,anon,authenticated;
revoke all on function public.my_network(text,text,integer) from public,anon;grant execute on function public.my_network(text,text,integer) to authenticated;
-- Free registered members may introduce vendors; explicit vendor links are validated.
do $$declare f text;begin
 f:=pg_get_functiondef('public.submit_vendor_application(text,text,text,text,text,numeric,text)'::regprocedure);
 f:=replace(f,'if m.status<>''active'' and not consumer then','if m.terms_accepted_at is null then');
 f:=replace(f,'intro:=m.sponsor_id;','intro:=m.sponsor_id; if nullif(trim(p_introducer_code),'''') is not null then select user_id into intro from public.member_profiles where user_id<>auth.uid() and status in(''active'',''inactive'') and terms_accepted_at is not null and (member_code=''MIO-''||regexp_replace(upper(trim(p_introducer_code)),''^MIO-'','''') or referral_code=regexp_replace(upper(trim(p_introducer_code)),''-[LR]$'',''''));if intro is null then raise exception ''Invalid vendor invitation'';end if;end if;');execute f;
end $$;
update public.package_versions set display_name=case package_code when 'BASIC_1' then 'Basic' when 'BASIC_2' then 'Brown' when 'ADVANCED_1' then 'Silver' when 'ADVANCED_2' then 'Gold' when 'PREMIUM' then 'Platinum' else display_name end;

alter function public.company_master_dashboard() rename to company_master_dashboard_before_ecommerce;
create function public.company_master_dashboard() returns jsonb language plpgsql security definer set search_path='' as $$declare result jsonb;begin
 if not private.has_role('admin') then raise exception 'Master account access required';end if;
 result:=public.company_master_dashboard_before_ecommerce();
 return result||jsonb_build_object('credited_ecommerce_mio',(select coalesce(sum(amount),0) from public.ecommerce_rewards where status='posted'),'held_ecommerce_mio',(select coalesce(sum(amount),0) from public.ecommerce_rewards where status in('held_activation','pending_delivery')),
 'top_network',coalesce((select jsonb_agg(x) from(select m.full_name,m.member_code,sum(e.amount) income from (select beneficiary_id,payable_amount amount from public.bonus_transactions where status='posted' union all select beneficiary_id,amount from public.ecommerce_rewards where status='posted')e join public.member_profiles m on m.user_id=e.beneficiary_id where m.user_id<>(select company_id from private.network_foundation where singleton) group by m.user_id order by sum(e.amount) desc limit 10)x),'[]'));
end $$;
revoke all on function public.company_master_dashboard_before_ecommerce() from public,anon,authenticated;
revoke all on function public.company_master_dashboard() from public,anon;grant execute on function public.company_master_dashboard() to authenticated;

revoke all on function private.company_treasury_sources() from public,anon,authenticated;


-- ===== schema/20261006182721_affiliate_buyer_reward_exclusion.sql =====
-- A buyer using another member's selling link receives the retail discount only.
-- If that buyer is also an ancestor/introducer, their would-be share remains company leftover.
do $$declare f text;begin
 f:=pg_get_functiondef('private.prepare_order_rewards()'::regprocedure);
 f:=replace(f,'values(o.id,new.id,r.who,r.kind,r.rate,b,amt)','values(o.id,new.id,case when o.selling_affiliate_id is not null and r.who=o.buyer_id then null else r.who end,r.kind,r.rate,b,amt)');execute f;
 f:=pg_get_functiondef('private.post_network_bonus(uuid,uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric,jsonb)'::regprocedure);
 f:=replace(f,'if amount<=0 then return;end if;','if amount<=0 then return;end if; if oid is not null and exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=who) then return;end if;');execute f;
 f:=pg_get_functiondef('private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb)'::regprocedure);
 f:=replace(f,'if oid is not null and trunc(b*.5,4)>0 then','if oid is not null and trunc(b*.5,4)>0 and not exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=p) then');execute f;
end $$;


-- ===== schema/20261007170159_awarded_reward_percentage.sql =====
alter table public.vendors add column awarded_rate numeric(8,6);
alter table public.products add column awarded_rate_override numeric(8,6);
alter table public.order_items add column awarded_rate_snapshot numeric(8,6),add column award_scope_snapshot text,add column award_policy_leftover_pkr numeric(18,4) not null default 0;
create function private.guard_vendor_award() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.commission_rate is null or new.commission_rate<.05 or new.commission_rate>1 then raise exception 'Agreement percentage is required and must cover company 5 percent';end if;
 if new.awarded_rate is not null and (new.awarded_rate<0 or new.awarded_rate>new.commission_rate-.05) then raise exception 'Awarded percentage must be between zero and agreement minus company 5 percent';end if;
 if exists(select 1 from public.products where vendor_id=new.id and awarded_rate_override>new.commission_rate-.05) then raise exception 'Reduce product overrides before reducing the vendor agreement';end if;return new;
end $$;
create trigger zz_vendor_award_guard before insert or update on public.vendors for each row execute function private.guard_vendor_award();
create or replace function private.formula_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$declare v public.vendors%rowtype;r numeric;begin
 select * into v from public.vendors where id=new.vendor_id;r:=coalesce(new.awarded_rate_override,v.awarded_rate,v.commission_rate-.05);
 if r is null or r<0 or r>v.commission_rate-.05 then raise exception 'Awarded percentage exceeds the available vendor reward budget';end if;
 if TG_OP='INSERT' and new.awarded_rate_override is not null and not private.has_role('admin') then raise exception 'Only admin may set product reward overrides';end if;
 if TG_OP='UPDATE' and new.awarded_rate_override is distinct from old.awarded_rate_override and not private.has_role('admin') then raise exception 'Only admin may set product reward overrides';end if;
 new.ppv_per_unit:=trunc(new.price_pkr*r/300,4);return new;
end $$;
create or replace function private.refresh_vendor_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.commission_rate is distinct from old.commission_rate or new.awarded_rate is distinct from old.awarded_rate then update public.products set updated_at=now() where vendor_id=new.id;end if;return new;
end $$;
drop trigger refresh_vendor_ppv on public.vendors;
create trigger refresh_vendor_ppv after update of commission_rate,awarded_rate on public.vendors for each row execute function private.refresh_vendor_ppv();
create or replace function private.snapshot_item_ppv() returns trigger language plpgsql security definer set search_path='' as $$declare v public.vendors%rowtype;override_rate numeric;begin
 select * into v from public.vendors where id=new.vendor_id;select awarded_rate_override into override_rate from public.products where id=new.product_id;
 new.awarded_rate_snapshot:=coalesce(override_rate,v.awarded_rate,new.commission_rate_snapshot-.05);
 new.award_scope_snapshot:=case when override_rate is not null then 'product' else 'vendor' end;
 new.ppv_per_unit_snapshot:=trunc(new.unit_price_pkr*new.awarded_rate_snapshot/300,4);
 new.award_policy_leftover_pkr:=trunc(new.unit_price_pkr*new.quantity*(new.commission_rate_snapshot-.05-new.awarded_rate_snapshot),4);return new;
end $$;
update public.products set updated_at=now();
update public.system_config set config_value=jsonb_set(config_value,'{shopping_ppv_factor}','1') where config_key='MLM_PLANS' and effective_to is null;
create function public.admin_set_vendor_rewards(p_vendor_id uuid,p_commission numeric,p_awarded numeric default null) returns void language plpgsql security definer set search_path='' as $$declare v public.vendors%rowtype;begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 if p_commission is null or p_commission<.05 or p_commission>1 or p_commission<>round(p_commission,6) then raise exception 'Agreement percentage is required';end if;
 select * into v from public.vendors where id=p_vendor_id for update;if v.id is null then raise exception 'Vendor not found';end if;
 update public.vendors set commission_rate=p_commission,awarded_rate=p_awarded where id=v.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'VENDOR_REWARD_POLICY','vendor',v.id,jsonb_build_object('commission',v.commission_rate,'awarded',v.awarded_rate),jsonb_build_object('commission',p_commission,'awarded',p_awarded));
end $$;
create function public.admin_set_product_reward(p_product_id uuid,p_awarded numeric default null) returns void language plpgsql security definer set search_path='' as $$declare before_rate numeric;begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 select awarded_rate_override into before_rate from public.products where id=p_product_id for update;if not found then raise exception 'Product not found';end if;
 update public.products set awarded_rate_override=p_awarded,updated_at=now() where id=p_product_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'PRODUCT_REWARD_POLICY','product',p_product_id,jsonb_build_object('awarded',before_rate),jsonb_build_object('awarded',p_awarded));
end $$;
-- Every vendor application must have explicit accepted commission terms, including legacy proposals.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_review_vendor_application(uuid,boolean,numeric)'::regprocedure);
 f:=replace(f,'p_commission_rate<0 or','p_commission_rate<.05 or');
 f:=replace(f,'a.proposed_commission is not null and (a.agreement_accepted_at is null or a.agreed_commission is distinct from p_commission_rate)','(a.agreement_accepted_at is null or a.agreed_commission is null or a.agreed_commission is distinct from p_commission_rate)');execute f;
 f:=pg_get_functiondef('public.offer_vendor_commission(uuid,numeric,text)'::regprocedure);f:=replace(f,'p_rate<0 or','p_rate<.05 or');execute f;
end $$;
-- Subtract explicit policy withholding from generic conversion remainder; do not count it twice.
alter function private.company_treasury_sources() rename to company_treasury_sources_before_award;
create function private.company_treasury_sources() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.currency,case when s.currency='PKR' and s.source_type='order' and s.category in('shopping_conversion_leftover','ecommerce_conversion_leftover') then greatest(0,s.amount-coalesce((select sum(i.award_policy_leftover_pkr) from public.order_items i where i.order_id=s.source_id),0)) else s.amount end from private.company_treasury_sources_before_award() s
 union all select 'order_item',i.id,case when i.award_scope_snapshot='product' then 'product_award_leftover' else 'vendor_award_leftover' end,'PKR',i.award_policy_leftover_pkr from public.order_items i join public.orders o on o.id=i.order_id where o.rewards_credited_at is not null and o.payment_status='confirmed' and i.awarded_rate_snapshot is not null;
$$;
-- Zero-award PPV orders still need a funding event for complete company accounting.
do $$declare f text;begin
 f:=pg_get_functiondef('private.release_order_rewards()'::regprocedure);f:=replace(f,'elsif ppv>0 then','else');execute f;
end $$;
create function public.admin_finance_details() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 return jsonb_build_object(
 'company_rows',coalesce((select jsonb_agg(x) from(select t.category,t.currency,t.amount,t.updated_at,o.order_code,i.product_name_snapshot,v.business_name,i.commission_rate_snapshot,i.awarded_rate_snapshot from public.company_treasury_positions t left join public.commission_allocations a on t.source_type='commission' and a.id=t.source_id left join public.vendor_income_ledger l on t.source_type='vendor_sale' and l.id=t.source_id left join public.ecommerce_rewards e on t.source_type='ecommerce' and e.id=t.source_id left join public.order_items i on i.id=case when t.source_type='order_item' then t.source_id else coalesce(a.order_item_id,l.order_item_id,e.order_item_id) end left join public.orders o on o.id=case when t.source_type='order' then t.source_id else i.order_id end left join public.vendors v on v.id=i.vendor_id where t.amount<>0 order by t.updated_at desc limit 250)x),'[]'),
 'system_rows',coalesce((select jsonb_agg(x) from(select m.full_name,m.member_code,l.amount,'MIO' currency,l.action kind,l.reason,l.created_at,o.order_code from public.mio_ledger l join public.member_profiles m on m.user_id=l.member_id left join public.orders o on o.id=l.source_order_id
 union all select m.full_name,m.member_code,p.amount,p.point_type::text,p.entry_kind::text,'Points ledger',p.created_at,o.order_code from public.point_ledger p join public.member_profiles m on m.user_id=p.member_id left join public.orders o on o.id=p.source_order_id order by created_at desc limit 250)x),'[]'),
 'company_wallet',coalesce((select jsonb_agg(x) from(select l.action,l.amount,l.reason,l.created_at,m.full_name,m.member_code from public.mio_ledger l left join public.member_profiles m on m.user_id=l.counterparty_id where l.member_id=(select company_id from private.network_foundation where singleton) order by l.created_at desc limit 100)x),'[]'));
end $$;
revoke all on function private.guard_vendor_award(),private.company_treasury_sources(),private.company_treasury_sources_before_award() from public,anon,authenticated;
revoke all on function public.admin_set_vendor_rewards(uuid,numeric,numeric),public.admin_set_product_reward(uuid,numeric),public.admin_finance_details() from public,anon;
grant execute on function public.admin_set_vendor_rewards(uuid,numeric,numeric),public.admin_set_product_reward(uuid,numeric),public.admin_finance_details() to authenticated;
notify pgrst,'reload schema';

create function public.admin_create_company_brand(p_name text,p_logo text,p_description text,p_commission numeric,p_awarded numeric default null) returns uuid language plpgsql security definer set search_path='' as $$declare vid uuid;begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 if p_commission is null then raise exception 'Enter the brand agreement percentage';end if;
 vid:=public.create_company_brand(p_name,p_logo,p_description);perform public.admin_set_vendor_rewards(vid,p_commission,p_awarded);return vid;
end $$;
revoke all on function public.admin_create_company_brand(text,text,text,numeric,numeric) from public,anon;grant execute on function public.admin_create_company_brand(text,text,text,numeric,numeric) to authenticated;
revoke execute on function public.create_company_brand(text,text,text) from authenticated;
do $$declare f text;begin
 f:=pg_get_functiondef('public.submit_vendor_application(text,text,text,text,text,numeric,text)'::regprocedure);
 f:=replace(f,'if p_proposed is distinct from 0.20 then raise exception ''Proposed vendor commission must be 20 percent''; end if;','if p_proposed is null or p_proposed<.05 or p_proposed>1 then raise exception ''Proposed agreement percentage is required (5 to 100 percent)'';end if;');
 f:=replace(f,'p_description,0.20,intro','p_description,p_proposed,intro');execute f;
end $$;


-- ===== schema/20261007220500_product_discount_reward_budget.sql =====
-- Preserve the seller's submitted price separately from the admin-facing sale price.
alter table public.products add column vendor_submitted_price_pkr numeric(14,2);
update public.products set vendor_submitted_price_pkr=price_pkr where vendor_submitted_price_pkr is null;
alter table public.products alter column vendor_submitted_price_pkr set not null;
alter table public.order_items add column reward_basis_pkr_snapshot numeric(18,2);
alter table public.order_items add column sale_discount_pkr_snapshot numeric(18,2) not null default 0;

create or replace function private.formula_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$
declare v public.vendors%rowtype; base numeric; discount_rate numeric; available_rate numeric; award_rate numeric;
begin
 select * into v from public.vendors where id=new.vendor_id;
 if TG_OP='INSERT' then new.vendor_submitted_price_pkr:=new.price_pkr;
 elsif not private.has_role('admin') and new.price_pkr is distinct from old.price_pkr then new.vendor_submitted_price_pkr:=new.price_pkr;
 elsif new.vendor_submitted_price_pkr is distinct from old.vendor_submitted_price_pkr then
  raise exception 'Seller submitted price is preserved; use sale price controls';
 else new.vendor_submitted_price_pkr:=old.vendor_submitted_price_pkr; end if;
 base:=new.vendor_submitted_price_pkr;
 if base<=0 and new.status='archived' then new.ppv_per_unit:=0;return new;elsif base<=0 then raise exception 'Seller submitted price must be positive';end if;
 if new.price_pkr>base then raise exception 'Sale price cannot exceed seller submitted price';end if;
 discount_rate:=greatest(base-new.price_pkr,0)/base;
 available_rate:=v.commission_rate-.05-discount_rate;
 if available_rate<0 then raise exception 'Discount exceeds commission after fixed company 5 percent';end if;
 award_rate:=coalesce(new.awarded_rate_override,v.awarded_rate,available_rate);
 if award_rate<0 or award_rate>available_rate then raise exception 'Award percentage exceeds the remaining budget after discount';end if;
 if TG_OP='INSERT' and new.awarded_rate_override is not null and not private.has_role('admin') then raise exception 'Only admin may set product reward overrides';end if;
 if TG_OP='UPDATE' and new.awarded_rate_override is distinct from old.awarded_rate_override and not private.has_role('admin') then raise exception 'Only admin may set product reward overrides';end if;
 new.ppv_per_unit:=trunc(base*award_rate/300,4);return new;
end $$;

create or replace function private.guard_vendor_award() returns trigger language plpgsql security definer set search_path='' as $$
declare min_budget numeric;
begin
 if new.commission_rate is null or new.commission_rate<.05 or new.commission_rate>1 then raise exception 'Agreement percentage is required and must cover company 5 percent';end if;
 select min(new.commission_rate-.05-greatest(vendor_submitted_price_pkr-price_pkr,0)/vendor_submitted_price_pkr) into min_budget from public.products where vendor_id=new.id;
 if new.awarded_rate is not null and new.awarded_rate>coalesce(min_budget,new.commission_rate-.05) then raise exception 'Vendor reward percentage exceeds a product budget after discount';end if;
 if exists(select 1 from public.products where vendor_id=new.id and awarded_rate_override>new.commission_rate-.05-greatest(vendor_submitted_price_pkr-price_pkr,0)/vendor_submitted_price_pkr) then raise exception 'Reduce product overrides before reducing the vendor agreement';end if;return new;
end $$;

-- Keep MIO conversion leftovers separate from PKR price-budget retention.
create or replace function private.company_treasury_sources() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.currency,s.amount from private.company_treasury_sources_before_award() s
 union all select 'order_item',i.id,case when i.award_scope_snapshot='product' then 'product_award_leftover' else 'vendor_award_leftover' end,'PKR',i.award_policy_leftover_pkr from public.order_items i join public.orders o on o.id=i.order_id where o.rewards_credited_at is not null and o.payment_status='confirmed' and i.awarded_rate_snapshot is not null;
$$;

create or replace function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$
declare v public.vendors%rowtype; p public.products%rowtype; base numeric; discount numeric; available_rate numeric; award_rate numeric; leftover_rate numeric;
begin
 select * into v from public.vendors where id=new.vendor_id;select * into p from public.products where id=new.product_id;
 if v.commission_rate<.05 then raise exception 'Vendor commission must cover company 5 percent';end if;
 base:=p.vendor_submitted_price_pkr*new.quantity;discount:=greatest(base-new.unit_price_pkr*new.quantity,0);available_rate:=v.commission_rate-.05-discount/nullif(base,0);
 award_rate:=coalesce(p.awarded_rate_override,v.awarded_rate,available_rate);leftover_rate:=available_rate-award_rate;
 if available_rate<0 or award_rate<0 or leftover_rate<0 then raise exception 'Product discount and awarded percentage exceed its funded budget';end if;
 new.reward_basis_pkr_snapshot:=base;new.sale_discount_pkr_snapshot:=discount;
 new.awarded_rate_snapshot:=award_rate;new.award_scope_snapshot:=case when p.awarded_rate_override is not null then 'product' else 'vendor' end;
 new.commission_rate_snapshot:=v.commission_rate;new.company_owned_snapshot:=v.is_company_owned;
 new.commission_split_snapshot:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',award_rate*100,'unallocated',leftover_rate*100);
 new.distribution_basis:='sale_v2';new.commission_pool_pkr:=round(base*v.commission_rate-discount,2);new.buyer_discount_pkr:=0;new.introducer_id_snapshot:=v.introduced_by;return new;
end $$;

create or replace function private.snapshot_item_ppv() returns trigger language plpgsql security definer set search_path='' as $$declare p public.products%rowtype;begin
 select * into p from public.products where id=new.product_id;
 new.reward_basis_pkr_snapshot:=p.vendor_submitted_price_pkr*new.quantity;
 new.sale_discount_pkr_snapshot:=greatest(new.reward_basis_pkr_snapshot-new.unit_price_pkr*new.quantity,0);
 new.awarded_rate_snapshot:=coalesce(p.awarded_rate_override,(select awarded_rate from public.vendors where id=new.vendor_id),new.commission_rate_snapshot-.05-new.sale_discount_pkr_snapshot/nullif(new.reward_basis_pkr_snapshot,0));
 new.award_scope_snapshot:=case when p.awarded_rate_override is not null then 'product' else 'vendor' end;
 new.ppv_per_unit_snapshot:=trunc(p.vendor_submitted_price_pkr*new.awarded_rate_snapshot/300,4);
 new.award_policy_leftover_pkr:=trunc(new.reward_basis_pkr_snapshot*greatest(0,new.commission_rate_snapshot-.05-new.sale_discount_pkr_snapshot/nullif(new.reward_basis_pkr_snapshot,0)-new.awarded_rate_snapshot),4);return new;
end $$;

-- Re-post each of the agreed percentages on the seller's submitted price basis;
-- the reduced sale price is the discount funded by the commission pool.
create or replace function private.post_vendor_sale() returns trigger language plpgsql security definer set search_path='' as $$
declare i public.order_items%rowtype; cumul numeric; previous numeric; k text; amount numeric; beneficiary uuid; state text; rate numeric; begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  for i in select * from public.order_items where order_id=new.id loop
   if i.distribution_basis<>'sale_v2' then raise exception 'Legacy unpaid order requires explicit reconciliation';end if;
   insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr) values(i.vendor_id,i.id,i.line_total_pkr,i.commission_pool_pkr,i.line_total_pkr-i.commission_pool_pkr) on conflict(order_item_id) do nothing;
   cumul:=0;previous:=0;
   foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'] loop
    rate:=(i.commission_split_snapshot->>k)::numeric;cumul:=cumul+rate;
    amount:=case k when 'buyer_discount' then i.buyer_discount_pkr else greatest(0,least(i.commission_pool_pkr-previous,round(coalesce(i.reward_basis_pkr_snapshot,i.line_total_pkr)*cumul/100,2)-previous)) end;previous:=previous+amount;
    beneficiary:=case k when 'buyer_discount' then new.buyer_id when 'company' then (select company_id from private.network_foundation limit 1) when 'affiliate' then i.affiliate_id_snapshot when 'sponsor' then i.sponsor_id_snapshot when 'second_upline' then i.second_upline_id_snapshot when 'introducer' then i.introducer_id_snapshot end;
    state:=case when k='buyer_discount' then 'discount_applied' when k='network_rewards' then 'reserved' when beneficiary is null then 'held' else 'earned' end;
    if amount>0 then insert into public.commission_allocations(order_item_id,share_kind,beneficiary_id,amount_pkr,status) values(i.id,k,beneficiary,amount,state) on conflict(order_item_id,share_kind) do nothing;end if;
   end loop;
   if previous<>i.commission_pool_pkr then raise exception 'Sale allocation does not reconcile';end if;
  end loop;perform private.post_shopping_rewards(new.id);
 end if;return new;
end $$;

create function public.admin_update_product_pricing(p_product_id uuid,p_sale_price numeric,p_compare_at numeric default null,p_awarded numeric default null) returns void language plpgsql security definer set search_path='' as $$
declare oldrow public.products%rowtype;begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 if p_sale_price is null or p_sale_price<=0 or p_sale_price<>round(p_sale_price,2) or (p_compare_at is not null and (p_compare_at<p_sale_price or p_compare_at<>round(p_compare_at,2))) or (p_awarded is not null and (p_awarded<0 or p_awarded<>round(p_awarded,6))) then raise exception 'Enter a valid sale price, optional crossed price and reward percentage';end if;
 select * into oldrow from public.products where id=p_product_id for update;if not found then raise exception 'Product not found';end if;
 update public.products set price_pkr=p_sale_price,compare_at_price_pkr=p_compare_at,awarded_rate_override=p_awarded,updated_at=now() where id=p_product_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'PRODUCT_PRICE_AND_REWARD', 'product',p_product_id,jsonb_build_object('vendor_price',oldrow.vendor_submitted_price_pkr,'sale_price',oldrow.price_pkr,'compare_at',oldrow.compare_at_price_pkr,'awarded',oldrow.awarded_rate_override),jsonb_build_object('vendor_price',oldrow.vendor_submitted_price_pkr,'sale_price',p_sale_price,'compare_at',p_compare_at,'awarded',p_awarded));
end $$;
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_finance_details()'::regprocedure);
 f:=replace(f,'i.commission_rate_snapshot,i.awarded_rate_snapshot from','i.commission_rate_snapshot,i.awarded_rate_snapshot,i.reward_basis_pkr_snapshot,i.sale_discount_pkr_snapshot,i.ppv_per_unit_snapshot from');
 execute f;
end $$;
revoke all on function public.admin_update_product_pricing(uuid,numeric,numeric,numeric) from public,anon;grant execute on function public.admin_update_product_pricing(uuid,numeric,numeric,numeric) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261009103000_member_mio_transfer_receipt.sql =====
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


-- ===== schema/20261009140000_marketplace_vouchers_banners.sql =====
-- Human-readable order references and source-aware member receipts.
alter table public.orders add column if not exists legacy_order_code text;
update public.orders
set legacy_order_code=coalesce(legacy_order_code,order_code),
    order_code='ORD-'||to_char(created_at at time zone 'UTC','YYMMDD')||'-'||upper(substr(replace(id::text,'-',''),1,10))
where order_code not like 'ORD-%';

create or replace function private.assign_order_reference()
returns trigger language plpgsql security definer set search_path=''
as $$begin
 new.order_code:='ORD-'||to_char(coalesce(new.created_at,now()) at time zone 'UTC','YYMMDD')||'-'||upper(substr(replace(new.id::text,'-',''),1,10));
 return new;
end$$;
drop trigger if exists assign_order_reference on public.orders;
create trigger assign_order_reference before insert on public.orders for each row execute function private.assign_order_reference();

create or replace function public.lookup_my_bonus_receipt(p_bonus_id uuid)
returns table(
 bonus_id uuid, method public.bonus_method, generation integer, payable_amount numeric,
 status text, created_at timestamptz, qualifying_base numeric, rate numeric, formula_version text,
 source_order_id uuid, source_activation_id uuid, cycle_id uuid,
 source_name text, source_code text, source_order_code text, source_product text, source_kind text
)
language plpgsql stable security definer set search_path=''
as $$begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.bonus_transactions b where b.id=p_bonus_id and b.beneficiary_id=auth.uid()) then
  raise exception 'Earning record not found for this account';
 end if;
 return query
 select b.id,b.method,b.generation::integer,b.payable_amount,b.status::text,b.created_at,b.qualifying_base,b.rate,b.formula_version,
        b.source_order_id,b.source_activation_id,b.cycle_id,
        m.full_name,m.member_code,o.order_code,
        (select string_agg(i.product_name_snapshot,' · ' order by i.id) from public.order_items i where i.order_id=o.id),
        case when o.id is not null then 'Shopping order' when a.id is not null then 'Plan activation' when b.cycle_id is not null then 'Binary pool cycle' else 'Network bonus' end
 from public.bonus_transactions b
 left join public.orders o on o.id=b.source_order_id
 left join public.package_activations a on a.id=b.source_activation_id
 left join public.member_profiles m on m.user_id=coalesce(o.reward_owner_id,o.buyer_id,a.member_id)
 where b.id=p_bonus_id and b.beneficiary_id=auth.uid();
end$$;
revoke all on function public.lookup_my_bonus_receipt(uuid) from public,anon;
grant execute on function public.lookup_my_bonus_receipt(uuid) to authenticated;

create or replace function public.admin_set_marketplace_banners(p_banners jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$declare v integer; row jsonb; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if jsonb_typeof(p_banners)<>'array' or jsonb_array_length(p_banners)>6 then raise exception 'Add no more than six banner images'; end if;
 for row in select value from jsonb_array_elements(p_banners) loop
  if jsonb_typeof(row)<>'object' or coalesce(row->>'image_url','') !~ '^https://' or length(coalesce(row->>'title',''))>90 or length(coalesce(row->>'subtitle',''))>180 then raise exception 'Each banner needs a public HTTPS image and short text'; end if;
  if coalesce(row->>'cta_link','')<>'' and row->>'cta_link' !~ '^(#|https://)' then raise exception 'Banner button must use a site section or HTTPS link'; end if;
 end loop;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_HERO';
 update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_HERO' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MARKETPLACE_HERO',v,p_banners,clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_BANNERS_SAVED','system_config',jsonb_build_object('version',v,'slide_count',jsonb_array_length(p_banners)));
 return jsonb_build_object('version',v,'slides',jsonb_array_length(p_banners));
end$$;
revoke all on function public.admin_set_marketplace_banners(jsonb) from public,anon;
grant execute on function public.admin_set_marketplace_banners(jsonb) to authenticated;

do $$begin
 if to_regclass('storage.buckets') is not null then
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
   values('marketplace-banners','marketplace-banners',true,5242880,array['image/jpeg','image/png','image/webp'])
   on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
  execute 'drop policy if exists marketplace_banners_public_read on storage.objects';
  execute 'create policy marketplace_banners_public_read on storage.objects for select using(bucket_id=''marketplace-banners'')';
  execute 'drop policy if exists marketplace_banners_admin_insert on storage.objects';
  execute 'create policy marketplace_banners_admin_insert on storage.objects for insert to authenticated with check(bucket_id=''marketplace-banners'' and private.has_role(''admin''))';
  execute 'drop policy if exists marketplace_banners_admin_update on storage.objects';
  execute 'create policy marketplace_banners_admin_update on storage.objects for update to authenticated using(bucket_id=''marketplace-banners'' and private.has_role(''admin'')) with check(bucket_id=''marketplace-banners'' and private.has_role(''admin''))';
  execute 'drop policy if exists marketplace_banners_admin_delete on storage.objects';
  execute 'create policy marketplace_banners_admin_delete on storage.objects for delete to authenticated using(bucket_id=''marketplace-banners'' and private.has_role(''admin''))';
 end if;
end$$;


-- ===== schema/20261009142000_member_earning_history.sql =====
-- A member can request a compact, source-aware history for only their own bonuses.
create or replace function public.my_earning_history()
returns table(
 bonus_id uuid,
 method public.bonus_method,
 generation integer,
 payable_amount numeric,
 status text,
 created_at timestamptz,
 qualifying_base numeric,
 rate numeric,
 formula_version text,
 source_member_id uuid,
 source_name text,
 source_code text,
 source_package_code text,
 source_order_code text,
 source_product text,
 source_total_pkr numeric,
 source_order_status text,
 source_payment_status text,
 affiliate_name text,
 affiliate_code text,
 source_kind text,
 cycle_code text,
 calculation_trace jsonb
)
language plpgsql stable security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 return query
 select b.id,b.method,b.generation::integer,b.payable_amount,b.status::text,b.created_at,
        b.qualifying_base,b.rate,b.formula_version,
        coalesce(o.buyer_id,a.member_id),src.full_name,src.member_code,
        coalesce(a.package_code,current_plan.package_code),o.order_code,
        (select string_agg(i.product_name_snapshot,' · ' order by i.id)
           from public.order_items i where i.order_id=o.id),
        o.total_pkr,o.status::text,o.payment_status::text,
        affiliate.full_name,affiliate.member_code,
        case when o.id is not null then 'Shopping order'
             when a.id is not null then 'Plan activation'
             when b.cycle_id is not null then 'Binary pool cycle'
             else 'Network bonus' end,
        cycle.cycle_code,b.calculation_trace
 from public.bonus_transactions b
 left join public.orders o on o.id=b.source_order_id
 left join public.package_activations a on a.id=b.source_activation_id
 left join public.member_profiles src on src.user_id=coalesce(o.buyer_id,a.member_id)
 left join public.member_profiles affiliate on affiliate.user_id=o.selling_affiliate_id
 left join public.binary_cycles cycle on cycle.id=b.cycle_id
 left join lateral (
   select pa.package_code from public.package_activations pa
   where pa.member_id=o.buyer_id and pa.status='approved' and pa.activated_at<=b.created_at
   order by pa.activated_at desc,pa.requested_at desc limit 1
 ) current_plan on true
 where b.beneficiary_id=auth.uid()
 order by b.created_at desc,b.id;
end
$$;
revoke all on function public.my_earning_history() from public,anon;
grant execute on function public.my_earning_history() to authenticated;


-- ===== schema/20261009150000_marketplace_announcements.sql =====
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


-- ===== schema/20261009170000_featured_categories_and_vendor_products.sql =====
insert into public.system_config(config_key,version,config_value,effective_from)
values('MARKETPLACE_FEATURED_CATEGORIES',1,'[]'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

drop policy if exists "featured approved products are public" on public.featured_products;
create policy "featured approved products are public" on public.featured_products
for select to anon,authenticated using (
  exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
    where p.id=product_id and p.status='approved' and p.stock_quantity>0 and v.status='active')
);

create or replace function public.set_featured_products(p_product_ids uuid[])
returns integer language plpgsql security definer set search_path='' as $$
declare admin_id uuid:=auth.uid(); n integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if coalesce(array_length(p_product_ids,1),0)>6 then raise exception 'Select at most six featured products'; end if;
  if (select count(distinct x) from unnest(coalesce(p_product_ids,'{}'::uuid[])) x)<>coalesce(array_length(p_product_ids,1),0) then
    raise exception 'Duplicate featured product';
  end if;
  if exists(select 1 from unnest(coalesce(p_product_ids,'{}'::uuid[])) x
    where not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
      where p.id=x and p.status='approved' and p.stock_quantity>0 and v.status='active')) then
    raise exception 'Choose approved products from active vendors';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('mio-featured-products',0));
  delete from public.featured_products;
  insert into public.featured_products(position,product_id,selected_by)
    select ordinality::smallint,product_id,admin_id from unnest(coalesce(p_product_ids,'{}'::uuid[])) with ordinality u(product_id,ordinality);
  n:=coalesce(array_length(p_product_ids,1),0);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'FEATURED_PRODUCTS_SET','featured_products',jsonb_build_object('count',n,'product_ids',p_product_ids));
  return n;
end $$;
revoke all on function public.set_featured_products(uuid[]) from public,anon;
grant execute on function public.set_featured_products(uuid[]) to authenticated;

create or replace function public.admin_set_featured_categories(p_categories jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer; item jsonb; cat text; ids uuid[]; pid uuid;
begin
  if not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_categories)<>'array' or jsonb_array_length(p_categories)<>3 then
    raise exception 'Select exactly three featured categories';
  end if;
  if (select count(distinct value->>'category') from jsonb_array_elements(p_categories))<>3 then
    raise exception 'Choose three different categories';
  end if;
  for item in select value from jsonb_array_elements(p_categories) loop
    cat:=trim(coalesce(item->>'category',''));
    if cat='' or jsonb_typeof(item->'product_ids')<>'array' or jsonb_array_length(item->'product_ids')<>3 then
      raise exception 'Choose exactly three products for each category';
    end if;
    ids:=array(select value::uuid from jsonb_array_elements_text(item->'product_ids'));
    if cardinality(ids)<>3 or (select count(distinct x) from unnest(ids) x)<>3 then
      raise exception 'Each category must have three different products';
    end if;
    foreach pid in array ids loop
      if not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
        where p.id=pid and p.category=cat and p.status='approved' and p.stock_quantity>0 and v.status='active') then
        raise exception 'Featured products must be approved, active, and belong to their selected category';
      end if;
    end loop;
  end loop;
  select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_FEATURED_CATEGORIES';
  update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_FEATURED_CATEGORIES' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
    values('MARKETPLACE_FEATURED_CATEGORIES',v,p_categories,clock_timestamp(),auth.uid());
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(auth.uid(),'FEATURED_CATEGORIES_SAVED','system_config',jsonb_build_object('version',v,'categories',p_categories));
  return jsonb_build_object('version',v,'categories',jsonb_array_length(p_categories));
end $$;
revoke all on function public.admin_set_featured_categories(jsonb) from public,anon;
grant execute on function public.admin_set_featured_categories(jsonb) to authenticated;


-- ===== schema/20261009210000_editable_mlm_distribution_budgets.sql =====
-- Master-editable reward budgets. Each event keeps the rules version captured when it was created.
alter table public.binary_cycles drop constraint if exists binary_cycles_pool_rate_check;
alter table public.binary_cycles add constraint binary_cycles_pool_rate_check check(pool_rate between 0 and 1);

-- Shopping reward records may follow any safely configured split whose total fits its funded BV.
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_direct_generation_mio_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_single_line_mio_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_binary_reserve_mio_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_check;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_check1;
alter table public.shopping_reward_events drop constraint if exists shopping_reward_events_check2;
alter table public.shopping_reward_events add constraint shopping_reward_events_budget_nonnegative check(direct_generation_mio>=0 and single_line_mio>=0 and binary_reserve_mio>=0);
alter table public.shopping_reward_events add constraint shopping_reward_events_budget_within_bv check(direct_generation_mio+single_line_mio+binary_reserve_mio<=bv);

-- Preserve the existing master/TOTP and optimistic version checks while adding budget inputs.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_save_plan(text,jsonb,integer)'::regprocedure);
 f:=replace(f,'key text;begin','key text;dg_cap numeric;sl_cap numeric;binary_rate numeric;begin');
 if position('dg_cap numeric' in f)=0 then raise exception 'Could not extend admin_save_plan declarations';end if;
 f:=replace(f,
  $old$if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;$old$,
  $new$if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 if (p_plan ? 'direct_generation_cap' and jsonb_typeof(p_plan->'direct_generation_cap')<>'number') or (p_plan ? 'single_line_cap' and jsonb_typeof(p_plan->'single_line_cap')<>'number') or (p_plan ? 'binary_pool_rate' and jsonb_typeof(p_plan->'binary_pool_rate')<>'number') then raise exception 'Distribution budget inputs must be numeric';end if;
 dg_cap:=coalesce((p_plan->>'direct_generation_cap')::numeric,(cfg->>'direct_generation_cap')::numeric,.55);sl_cap:=coalesce((p_plan->>'single_line_cap')::numeric,(cfg->>'single_line_cap')::numeric,.10);binary_rate:=coalesce((p_plan->>'binary_pool_rate')::numeric,(cfg->>'binary_pool_rate')::numeric,.35);
 if dg_cap<0 or sl_cap<0 or binary_rate<0 or dg_cap>1 or sl_cap>1 or binary_rate>1 or dg_cap+sl_cap+binary_rate>1.000000000001 then raise exception 'Distribution budgets must each be between 0 and 100 percent and total no more than 100 percent';end if;
 cfg:=jsonb_set(jsonb_set(jsonb_set(cfg,'{direct_generation_cap}',to_jsonb(dg_cap),true),'{single_line_cap}',to_jsonb(sl_cap),true),'{binary_pool_rate}',to_jsonb(binary_rate),true);$new$);
 if position('dg_cap:=coalesce((p_plan' in f)=0 then raise exception 'Could not add distribution budget validation';end if;
 f:=replace(f,'if tot>.100000000001 then raise exception ''Single-line total cannot exceed the funded 10 percent budget'';end if;',
  'if tot>sl_cap+0.000000000001 then raise exception ''Single-line total cannot exceed the configured budget'';end if;');
 if position('tot>sl_cap' in f)=0 then raise exception 'Could not make single-line validation configurable';end if;
 f:=replace(f,$old$jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan)$old$,$new$jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'direct_generation_cap',dg_cap,'single_line_cap',sl_cap,'binary_pool_rate',binary_rate)$new$);
 execute f;
end $$;

-- Capture the selected binary share on new package activations; orders keep the full rules snapshot as before.
create or replace function private.snapshot_mlm_rules() returns trigger language plpgsql security definer set search_path='' as $$begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then
  new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(least(new.bv,new.base_value,new.payable_price-new.company_fee)*coalesce((new.rules_snapshot->>'binary_pool_rate')::numeric,.35),4) else 0 end;
 end if;
 return new;
end $$;

-- Direct/generation and single-line caps are read from the event's immutable snapshot.
do $$declare f text;begin
 f:=pg_get_functiondef('private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb)'::regprocedure);
 f:=replace(f,'trunc(b*.55,4)','trunc(b*coalesce((cfg->>''direct_generation_cap'')::numeric,.55),4)');
 f:=replace(f,'trunc(b*.10,4)','trunc(b*coalesce((cfg->>''single_line_cap'')::numeric,.10),4)');
 if position('cfg->>''direct_generation_cap''' in f)=0 or position('cfg->>''single_line_cap''' in f)=0 then raise exception 'Could not make MLM event caps configurable';end if;
 execute f;
end $$;

-- Protect all bonus writers against the configured source-event cap, including package activations.
create or replace function private.guard_bonus_funding() returns trigger language plpgsql security definer set search_path='' as $$
declare b numeric;spent numeric;ceiling numeric;cfg jsonb;begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then
   select s.bv,o.rules_snapshot into b,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else
   select least(a.bv,a.base_value,a.payable_price-a.company_fee),a.rules_snapshot into b,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;
  end if;
  ceiling:=trunc(b*case when new.method='single_line' then coalesce((cfg->>'single_line_cap')::numeric,.10) else coalesce((cfg->>'direct_generation_cap')::numeric,.55) end,4);
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where status in('posted','pending') and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id)) and case when new.method='single_line' then method='single_line' else method in('direct','generation') end;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling then raise exception 'Bonus would exceed its funded source budget';end if;return new;
end $$;

-- E-commerce PPV mode reserves the configured binary share for the same source event.
do $$declare f text;begin
 f:=pg_get_functiondef('private.release_order_rewards()'::regprocedure);
 f:=replace(f,'trunc(ppv*.35,4)','trunc(ppv*coalesce((o.rules_snapshot->>''binary_pool_rate'')::numeric,.35),4)');
 if position('o.rules_snapshot->>''binary_pool_rate''' in f)=0 then raise exception 'Could not make order binary reserve configurable';end if;
 execute f;
end $$;

-- A cycle contains event-level reserves (which can have different historical rates).
-- Store its effective aggregate rate while distributing the exact reserved pool.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_close_binary_cycle(text,timestamptz,timestamptz,text)'::regprocedure);
 f:=replace(f,'eligible numeric; pool numeric;','eligible numeric; pool numeric; effective_rate numeric;');
 if position('effective_rate numeric' in f)=0 then raise exception 'Could not add binary effective rate';end if;
 f:=replace(f,'eligible:=eligible+(select coalesce(sum(bv),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);',
  'eligible:=eligible+(select coalesce(sum(bv),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);'||chr(10)||
  ' effective_rate:=case when eligible>0 then pool/eligible else coalesce((private.current_mlm_rules()->>''binary_pool_rate'')::numeric,.35) end;');
 f:=replace(f,'eligible,p_timezone,p_timezone','eligible,p_timezone,p_timezone');
 f:=replace(f,'p_timezone,eligible,0.35,pool','p_timezone,eligible,effective_rate,pool');
 f:=replace(f,$old$'pool_rate',0.35$old$,$new$'pool_rate',effective_rate$new$);
 if position('effective_rate:=case' in f)=0 or position('eligible,effective_rate,pool' in f)=0 then raise exception 'Could not make binary cycle rate configurable';end if;
 execute f;
end $$;

-- Company pending budgets use the same rates saved with each package/order event.
create or replace function private.company_treasury_sources_before_ecommerce() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 with funding as(
  select 'order'::text typ,s.order_id id,s.bv base,s.binary_reserve_mio reserve,
   coalesce((o.rules_snapshot->>'direct_generation_cap')::numeric,.55) dg_cap,coalesce((o.rules_snapshot->>'single_line_cap')::numeric,.10) sl_cap
  from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all
  select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.binary_reserve_mio,
   coalesce((a.rules_snapshot->>'direct_generation_cap')::numeric,.55),coalesce((a.rules_snapshot->>'single_line_cap')::numeric,.10)
  from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ), spend as(
  select f.*,coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status in('posted','pending') and ((f.typ='order' and b.source_order_id=f.id) or (f.typ='package' and b.source_activation_id=f.id)) and b.method in('direct','generation')),0) dg,
   coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status in('posted','pending') and ((f.typ='order' and b.source_order_id=f.id) or (f.typ='package' and b.source_activation_id=f.id)) and b.method='single_line'),0) sl
  from funding f
 )
 select typ,id,'direct_generation_leftover','MIO',greatest(0,trunc(base*dg_cap,4)-dg) from spend
 union all select typ,id,'single_line_leftover','MIO',greatest(0,trunc(base*sl_cap,4)-sl) from spend
 union all select typ,id,'network_rounding_leftover','MIO',greatest(0,base-trunc(base*dg_cap,4)-trunc(base*sl_cap,4)-reserve) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*300) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$$;
revoke all on function private.snapshot_mlm_rules(),private.guard_bonus_funding(),private.release_order_rewards(),private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261009213900_automatic_weekly_binary_pool.sql =====
-- Automatically settle every completed Monday-to-Monday binary period in Pakistan time.
-- The job catches up missed runs, but never closes a partial week.
create or replace function private.run_automatic_binary_pool()
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
 company uuid;
 earliest_event timestamptz;
 completed_through timestamptz;
 cycle_start timestamptz;
 cycle_end timestamptz;
 v_cycle_code text;
 settled integer:=0;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('mio-automatic-binary-pool',0)) then return 0; end if;
 select company_id into company from private.network_foundation where singleton limit 1;
 if company is null then return 0; end if;
 select min(event_at) into earliest_event from(
  select a.activated_at event_at from public.package_activations a where a.status='approved'
  union all
  select s.created_at from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all
  select p.created_at from public.point_ledger p where p.point_type='BP' and p.entry_kind='credit'
 ) events;
 if earliest_event is null then return 0; end if;
 completed_through:=date_trunc('week',now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi';
 select max(ends_at) into cycle_start from public.binary_cycles where status<>'reversed';
 if cycle_start is null then
  cycle_start:=date_trunc('week',earliest_event at time zone 'Asia/Karachi') at time zone 'Asia/Karachi';
 end if;
 if cycle_start>=completed_through then return 0; end if;
 perform set_config('request.jwt.claim.sub',company::text,true);
 while cycle_start<completed_through and settled<100 loop
  cycle_end:=(date_trunc('week',cycle_start at time zone 'Asia/Karachi')+interval '7 days') at time zone 'Asia/Karachi';
  if cycle_end>completed_through then exit; end if;
  v_cycle_code:='AUTO-'||to_char(cycle_start at time zone 'Asia/Karachi','IYYY-"W"IW');
  if not exists(select 1 from public.binary_cycles where binary_cycles.cycle_code=v_cycle_code) then
   perform public.admin_close_binary_cycle(v_cycle_code,cycle_start,cycle_end,'Asia/Karachi');
   settled:=settled+1;
  end if;
  cycle_start:=cycle_end;
 end loop;
 return settled;
end
$$;
revoke all on function private.run_automatic_binary_pool() from public,anon,authenticated;

-- Enable the managed scheduler when available. Local PostgreSQL test doubles can still
-- load and exercise the settlement function without installing Supabase's extension.
do $$begin
 if to_regclass('cron.job') is null and exists(select 1 from pg_available_extensions where name='pg_cron') then
  execute 'create extension if not exists pg_cron with schema pg_catalog';
 end if;
 if to_regclass('cron.job') is not null then
  execute 'grant usage on schema cron to postgres';
  execute 'grant all privileges on all tables in schema cron to postgres';
  execute $schedule$select cron.schedule('mio-automatic-binary-pool','5 19 * * *','select private.run_automatic_binary_pool();')$schedule$;
 end if;
end$$;


-- ===== schema/20261010000000_require_product_category.sql =====
-- Products always belong to a named marketplace category.
-- Existing live rows were checked and contain no null or blank categories.
alter table public.products alter column category set not null;
alter table public.products add constraint products_category_nonblank
  check (length(btrim(category)) >= 2);


-- ===== schema/20261010010000_marketplace_categories.sql =====
insert into public.system_config(config_key,version,config_value,effective_from)
values('MARKETPLACE_CATEGORIES',1,'[{"name":"Electronics & Accessories","slug":"electronics","icon":"electronics"},{"name":"Women’s Fashion","slug":"womens-fashion","icon":"womens-fashion"},{"name":"Men’s Fashion","slug":"mens-fashion","icon":"mens-fashion"},{"name":"Home & Living","slug":"home-living","icon":"home-living"},{"name":"Beauty & Personal Care","slug":"beauty","icon":"beauty"},{"name":"Health & Wellness","slug":"health","icon":"health"},{"name":"Grocery & Food","slug":"grocery","icon":"grocery"},{"name":"Sports & Outdoors","slug":"sports","icon":"sports"},{"name":"Toys & Baby","slug":"toys","icon":"toys"},{"name":"Books & Stationery","slug":"books","icon":"books"},{"name":"Automotive","slug":"automotive","icon":"automotive"},{"name":"Jewellery & Accessories","slug":"jewellery","icon":"jewellery"},{"name":"Hair & beard care","slug":"hair-beard-care","icon":"beauty"},{"name":"Skincare","slug":"skincare","icon":"skincare"},{"name":"Skincare bundles","slug":"skincare-bundles","icon":"beauty"}]'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_marketplace_categories(p_categories jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer; row jsonb; names text[]; slugs text[];
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if jsonb_typeof(p_categories)<>'array' or jsonb_array_length(p_categories)<3 or jsonb_array_length(p_categories)>40 then raise exception 'Add between 3 and 40 product categories'; end if;
 select array_agg(trim(value->>'name')),array_agg(trim(value->>'slug')) into names,slugs from jsonb_array_elements(p_categories);
 if exists(select 1 from unnest(names) n where n is null or length(n) not between 2 and 60) or
    exists(select 1 from unnest(slugs) s where s !~ '^[a-z0-9]+(-[a-z0-9]+)*$') or
    cardinality(names)<>(select count(distinct lower(n)) from unnest(names) n) or
    cardinality(slugs)<>(select count(distinct s) from unnest(slugs) s) then raise exception 'Category names and IDs must be valid and unique'; end if;
 if exists(select 1 from (select distinct category from public.products) p where not (p.category=any(names))) then raise exception 'Keep every category currently used by a product'; end if;
 if exists(select 1 from jsonb_array_elements(p_categories) x where coalesce(x->>'icon','') !~ '^[a-z0-9-]+$') then raise exception 'Choose a valid category icon'; end if;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_CATEGORIES';
 update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_CATEGORIES' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MARKETPLACE_CATEGORIES',v,p_categories,clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_CATEGORIES_SAVED','system_config',jsonb_build_object('version',v,'count',jsonb_array_length(p_categories)));
 return jsonb_build_object('version',v,'categories',jsonb_array_length(p_categories));
end $$;
revoke all on function public.admin_set_marketplace_categories(jsonb) from public,anon;
grant execute on function public.admin_set_marketplace_categories(jsonb) to authenticated;



-- ===== schema/20261010020000_enforce_marketplace_category.sql =====
do $$
declare f text;
begin
 f:=pg_get_functiondef('public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean)'::regprocedure);
 f:=replace(f,
   $needle$or length(trim(coalesce(p_category,'')))<2 or p_price is null$needle$,
   $replacement$or length(trim(coalesce(p_category,'')))<2 or not exists(select 1 from public.system_config c cross join lateral jsonb_array_elements(c.config_value) x where c.config_key='MARKETPLACE_CATEGORIES' and c.effective_to is null and x->>'name'=trim(p_category)) or p_price is null$replacement$);
 if f not like '%MARKETPLACE_CATEGORIES%' then raise exception 'Could not enforce marketplace category selection'; end if;
 execute f;
end $$;


-- ===== schema/20261010030000_seed_marketplace_banners.sql =====
do $$
declare current jsonb; v integer;
begin
 select config_value into current from public.system_config
 where config_key='MARKETPLACE_HERO' and effective_to is null
 order by version desc limit 1;
 if current is null or current='[]'::jsonb then
  update public.system_config set effective_to=clock_timestamp()
  where config_key='MARKETPLACE_HERO' and effective_to is null;
  select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_HERO';
  insert into public.system_config(config_key,version,config_value,effective_from)
  values('MARKETPLACE_HERO',v,'[
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/home-living-campaign.webp","title":"Make room for good living","subtitle":"Thoughtful finds for every corner of home.","cta_label":"Explore home","cta_link":"#catalog"},
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/winter-edit-campaign.webp","title":"Find your next favourite","subtitle":"Style, care and everyday essentials from local sellers.","cta_label":"Shop the edit","cta_link":"#catalog"},
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/sports-campaign.webp","title":"Move with confidence","subtitle":"Explore sports and active essentials.","cta_label":"Shop now","cta_link":"#catalog"},
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/winter-campaign.webp","title":"Your winter edit","subtitle":"Find cozy layers and seasonal favorites.","cta_label":"Explore products","cta_link":"#catalog"}
  ]'::jsonb,clock_timestamp());
 end if;
end $$;


-- ===== schema/20261010094227_member_tree_profile_photos_storage.sql =====
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



-- ===== schema/20261010094239_include_profile_photos_in_network_tree.sql =====
do $$declare f text;begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 f:=replace(f,'''package'',private.current_package_code(t.id),''rank'',m.achieved_rank,''joined_at'',m.created_at,','''package'',private.current_package_code(t.id),''rank'',m.achieved_rank,''joined_at'',m.created_at,''profile_photo_url'',m.profile_photo_url,');
 execute f;
end $$;
notify pgrst,'reload schema';


-- ===== schema/20261010101643_complete_member_ecommerce_history.sql =====
-- Full, paginatable personal history. The dashboard's 200-row operations preview
-- must not truncate a member's calendar or expose another recipient's earnings.
create or replace function public.my_ecommerce_history()
returns table(
 id uuid, beneficiary_id uuid, order_code text, product_name_snapshot text,
 reward_kind text, rate numeric, base_points numeric, amount numeric,
 status text, created_at timestamptz, source_name text, source_code text
)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 return query
 select e.id,e.beneficiary_id,o.order_code,i.product_name_snapshot,
        e.reward_kind,e.rate,e.base_points,e.amount,e.status,e.created_at,
        buyer.full_name,buyer.member_code
 from public.ecommerce_rewards e
 join public.orders o on o.id=e.order_id
 join public.order_items i on i.id=e.order_item_id
 left join public.member_profiles buyer on buyer.user_id=o.buyer_id
 where e.beneficiary_id=auth.uid()
 order by e.created_at desc,e.id;
end $$;
revoke all on function public.my_ecommerce_history() from public,anon;
grant execute on function public.my_ecommerce_history() to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261010110000_vendor_registration_switch.sql =====
-- Vendor applications can be paused publicly and are also guarded at the RPC.
insert into public.system_config(config_key,version,config_value,effective_from)
values('VENDOR_REGISTRATION',1,'true'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_vendor_registration(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_enabled is null then raise exception 'Choose whether seller applications are open or closed'; end if;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='VENDOR_REGISTRATION';
 update public.system_config set effective_to=clock_timestamp() where config_key='VENDOR_REGISTRATION' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('VENDOR_REGISTRATION',v,to_jsonb(p_enabled),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'VENDOR_REGISTRATION_SET','system_config',jsonb_build_object('enabled',p_enabled,'version',v));
 return jsonb_build_object('enabled',p_enabled,'version',v);
end $$;
revoke all on function public.admin_set_vendor_registration(boolean) from public,anon;
grant execute on function public.admin_set_vendor_registration(boolean) to authenticated;

-- Hiding the application page is only presentation; block direct RPC calls too.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.submit_vendor_application(text,text,text,text,text,numeric,text)'::regprocedure);
 f:=replace(f,E'begin\n if auth.uid() is null then',
   E'begin\n if coalesce((select config_value from public.system_config where config_key=''VENDOR_REGISTRATION'' and effective_to is null order by version desc limit 1),''true''::jsonb) <> ''true''::jsonb then raise exception ''Seller registration is currently closed''; end if;\n if auth.uid() is null then');
 if position('Seller registration is currently closed' in f)=0 then raise exception 'Could not add seller application availability guard'; end if;
 execute f;
end $$;
notify pgrst,'reload schema';


-- ===== schema/20261010144000_rename_membership_packages.sql =====
begin;

update public.package_versions
set display_name = case package_code
  when 'BASIC_1' then 'Starter'
  when 'BASIC_2' then 'Basic'
  when 'ADVANCED_1' then 'Silver'
  when 'ADVANCED_2' then 'Gold'
  when 'PREMIUM' then 'Platinum'
  else display_name
end
where package_code in ('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM');

update public.system_config
set config_value = jsonb_set(
  jsonb_set(config_value, '{plans,BASIC_1,display_name}', '"Starter"'::jsonb, true),
  '{plans,BASIC_2,display_name}', '"Basic"'::jsonb, true
)
where config_key = 'MLM_PLANS'
  and effective_to is null;

commit;


-- ===== schema/20261011135000_tree_binary_carry_and_lifetime_totals.sql =====
-- Keep carry-forward BP separate from lifetime binary volume in the graphical tree.
do $$
declare
 f text;
 old_fragment text;
 new_fragment text;
begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 old_fragment:='''right_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''RIGHT''),0)-coalesce((select sum(consumed_right) from public.binary_member_results where member_id=t.id),0)';
 new_fragment:=old_fragment||
  ',''total_left_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''LEFT''),0)'||
  ',''total_right_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''RIGHT''),0)';
 if position(old_fragment in f)=0 then
  raise exception 'Expected binary point fragment was not found in my_network_before_vendor_root';
 end if;
 f:=replace(f,old_fragment,new_fragment);
 execute f;
end
$$;

notify pgrst,'reload schema';


-- ===== schema/20261011190000_point_based_two_plan_model.sql =====
-- Final model: DP funds sponsor bonus and creates separate GP/BP plan bases.
alter table public.shopping_reward_events
 add column if not exists dp numeric(18,4),
 add column if not exists gp numeric(18,4),
 add column if not exists bp numeric(18,4);
update public.shopping_reward_events set dp=coalesce(dp,bv),gp=coalesce(gp,trunc(bv*.5,4)),bp=coalesce(bp,trunc(bv*.5,4));
alter table public.shopping_reward_events alter column dp set not null,alter column gp set not null,alter column bp set not null;
alter table public.shopping_reward_events add constraint shopping_reward_events_point_bases_nonnegative check(dp>=0 and gp>=0 and bp>=0);

do $$
declare cfg jsonb;v integer;plan_key text;level_count integer;rates jsonb;i integer;
begin
 select config_value into cfg from public.system_config where config_key='MLM_PLANS' and effective_to is null for update;
 v:=(cfg->>'version')::integer;
 cfg:=(cfg-'direct_generation_cap')||jsonb_build_object(
  'version',v+1,'generation_plan_rate',.50,'binary_plan_rate',.50,
  'generation_bonus_rate',.45,'generation_manager_rate',.05,'generation_global_rate',.20,
  'binary_pool_rate',.35,'single_line_cap',.10,'binary_manager_rate',.05,'binary_global_rate',.20,
  'shopping_dp_factor',1
 );
 for plan_key in select jsonb_object_keys(cfg->'plans') loop
  level_count:=(cfg->'plans'->plan_key->>'max_generations')::integer;rates:='{}'::jsonb;
  if level_count>=2 then for i in 2..level_count loop rates:=rates||jsonb_build_object(i::text,.05);end loop;end if;
  cfg:=jsonb_set(cfg,array['plans',plan_key,'generation_rates'],rates,true);
 end loop;
 update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
end$$;

create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,private.package_eligible(u.id) eligible
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*(cfg->'plans'->case when eligible then coalesce(private.current_package_code(member),'BASIC_1') else 'BASIC_1' end->>'direct_rate')::numeric
       else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=(plan->>'max_generations')::integer);
$$;

create or replace function private.mlm_candidates(member uuid,b numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric)
language sql stable security definer set search_path='' as $$
 select c.beneficiary,c.method,c.depth,c.nominal from private.mlm_point_candidates(member,b,b,cfg)c;
$$;

create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare total numeric;scale numeric;amount numeric;r record;p uuid;current_member uuid:=member;side text;d integer:=0;plan jsonb;rates jsonb;cum numeric;prev numeric;direct_paid numeric:=0;gen_paid numeric:=0;sl numeric:=0;slscale numeric:=1;
 dp_base numeric:=b;gp_base numeric:=trunc(b*.5,4);bp_base numeric:=trunc(b*.5,4);gen_cap numeric;placement_cap numeric;
begin
 if oid is not null then select s.dp,s.gp,s.bp into dp_base,gp_base,bp_base from public.shopping_reward_events s where s.order_id=oid;
 elsif aid is not null then select a.dp,a.gp,a.bp into dp_base,gp_base,bp_base from public.package_activations a where a.id=aid;end if;
 dp_base:=coalesce(dp_base,b);gp_base:=coalesce(gp_base,trunc(dp_base*coalesce((cfg->>'generation_plan_rate')::numeric,.5),4));bp_base:=coalesce(bp_base,trunc(dp_base*coalesce((cfg->>'binary_plan_rate')::numeric,.5),4));
 gen_cap:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);placement_cap:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);
 select coalesce(sum(nominal),0) into total from private.mlm_point_candidates(member,dp_base,gp_base,cfg) where method='generation';
 scale:=case when total>0 then least(1,gen_cap/total) else 0 end;
 for r in select * from private.mlm_point_candidates(member,dp_base,gp_base,cfg) order by depth loop
  if r.method='direct' then amount:=trunc(r.nominal,4);direct_paid:=direct_paid+amount;else amount:=trunc(r.nominal*scale,4);gen_paid:=gen_paid+amount;end if;
  perform private.post_network_bonus(oid,aid,r.beneficiary,r.method,r.depth,r.qualifying_base,r.nominal,amount,cfg);
 end loop;
 select coalesce(sum(bp_base*coalesce((cfg->'plans'->private.current_package_code(x.id)->'single_line_rates'->>(x.depth-1))::numeric,0)),0) into total from (
  with recursive chain(id,depth,path) as(
   select q.parent_id,1,array[member,q.parent_id] from public.binary_placements q where q.member_id=member and q.parent_id is not null
   union all select q.parent_id,c.depth+1,c.path||q.parent_id from chain c join public.binary_placements q on q.member_id=c.id where q.parent_id is not null and c.depth<1000 and not q.parent_id=any(c.path)
  )select * from chain
 )x where private.package_eligible(x.id) and x.depth<=coalesce((cfg->'plans'->private.current_package_code(x.id)->>'single_line_levels')::integer,0);
 slscale:=case when total>0 then least(1,placement_cap/total) else 0 end;
 loop
  select q.parent_id,q.side into p,side from public.binary_placements q where q.member_id=current_member;exit when p is null;d:=d+1;if d>1000 then raise exception 'Placement ancestry exceeds supported depth';end if;
  if oid is not null and trunc(bp_base,4)>0 and not exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=p) then
   insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(bp_base,4),side,oid,'credit','shopping-bp:'||oid||':'||p) on conflict(idempotency_key) do nothing;end if;
  plan:=cfg->'plans'->private.current_package_code(p);
  if private.package_eligible(p) and d<=coalesce((plan->>'single_line_levels')::integer,0) then
   rates:=plan->'single_line_rates';select coalesce(sum(value::numeric),0) into cum from jsonb_array_elements_text(rates) with ordinality where ordinality<=d;select coalesce(sum(value::numeric),0) into prev from jsonb_array_elements_text(rates) with ordinality where ordinality<d;
   amount:=case when slscale=1 then trunc(round(bp_base*cum,12),4)-trunc(round(bp_base*prev,12),4) else trunc(bp_base*coalesce((rates->>(d-1))::numeric,0)*slscale,4) end;
   amount:=least(amount,greatest(0,placement_cap-sl));perform private.post_network_bonus(oid,aid,p,'single_line',d,bp_base,bp_base*coalesce((rates->>(d-1))::numeric,0),amount,cfg);sl:=sl+amount;end if;
  current_member:=p;
 end loop;
 return jsonb_build_object('direct',direct_paid,'generation',gen_paid,'direct_generation',direct_paid+gen_paid,'single_line',sl,'dp',dp_base,'gp',gp_base,'bp',bp_base);
end$$;

create or replace function private.snapshot_mlm_rules() returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(new.bp*coalesce((new.rules_snapshot->>'binary_pool_rate')::numeric,.35),4) else 0 end;end if;
 return new;
end$$;

create or replace function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;ppv numeric;total numeric;funding numeric;r record;outcome jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 select * into o from public.orders where id=new.id for update;
 if o.status in('cancelled','returned') and o.rewards_credited_at is null then update public.ecommerce_rewards set status='cancelled' where order_id=o.id and status='pending_delivery';return new;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if o.reward_version=1 then o.reward_owner_id:=o.buyer_id;perform private.post_shopping_rewards(o.id);
 else
  select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards';
  if ppv*300>funding then raise exception 'Order rewards exceed verified funding';end if;
  if o.reward_mode='MIO' then
   for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop perform private.credit_ecommerce_reward(r.id);end loop;
   update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;
  else
   dp_base:=trunc(ppv*coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric,1),4);gp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric,.5),4);bp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric,.5),4);
   insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,dp,gp,bp,binary_reserve_mio) values(o.id,o.reward_owner_id,funding,ppv,dp_base,gp_base,bp_base,trunc(bp_base*coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric,.35),4)) on conflict do nothing;
   if found then outcome:=private.distribute_mlm_event(o.reward_owner_id,ppv,o.id,null,o.rules_snapshot);update public.shopping_reward_events set direct_generation_mio=(outcome->>'direct_generation')::numeric,single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;end if;
  end if;
 end if;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.reward_owner_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);perform private.sync_company_treasury();return new;
end$$;

create or replace function private.guard_bonus_funding() returns trigger language plpgsql security definer set search_path='' as $$
declare spent numeric;ceiling numeric;cfg jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='binary_pool_share' then select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then select s.dp,s.gp,s.bp,o.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else select a.dp,a.gp,a.bp,a.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;end if;
  if new.method='direct' then ceiling:=new.gross_amount;elsif new.method='generation' then ceiling:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);else ceiling:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);end if;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where status in('posted','pending') and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id)) and method=new.method;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling then raise exception 'Bonus would exceed its funded source budget';end if;return new;
end$$;

create or replace function public.admin_save_plan(p_code text,p_plan jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;rate numeric;tot numeric;key text;gplan numeric;bplan numeric;genbonus numeric;genmanager numeric;genglobal numeric;placement numeric;pool numeric;bmanager numeric;bglobal numeric;
begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;perform private.require_recent_totp();perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 foreach key in array array['generation_plan_rate','binary_plan_rate','generation_bonus_rate','generation_manager_rate','generation_global_rate','single_line_cap','binary_pool_rate','binary_manager_rate','binary_global_rate'] loop if jsonb_typeof(p_plan->key)<>'number' then raise exception 'Missing numeric budget: %',key;end if;end loop;
 gplan:=(p_plan->>'generation_plan_rate')::numeric;bplan:=(p_plan->>'binary_plan_rate')::numeric;genbonus:=(p_plan->>'generation_bonus_rate')::numeric;genmanager:=(p_plan->>'generation_manager_rate')::numeric;genglobal:=(p_plan->>'generation_global_rate')::numeric;placement:=(p_plan->>'single_line_cap')::numeric;pool:=(p_plan->>'binary_pool_rate')::numeric;bmanager:=(p_plan->>'binary_manager_rate')::numeric;bglobal:=(p_plan->>'binary_global_rate')::numeric;
 if least(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)<0 or greatest(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)>1 then raise exception 'All percentages must be between 0 and 100';end if;
 if abs(gplan+bplan-1)>.000000001 then raise exception 'Generation Plan and Binary Plan must total exactly 100 percent';end if;if genbonus+genmanager+genglobal>1.000000001 then raise exception 'Generation breakdown exceeds 100 percent of GP';end if;if placement+pool+bmanager+bglobal>1.000000001 then raise exception 'Binary breakdown exceeds 100 percent of BP';end if;
 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','company_fee','ppv','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','single_line_levels'] loop if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 then raise exception 'Invalid plan value: %',key;end if;end loop;
 if (p_plan->>'base_value')::numeric<=0 or (p_plan->>'ppv')::numeric<=0 or (p_plan->>'bv')::numeric>(p_plan->>'base_value')::numeric or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;if (p_plan->>'bv')::numeric>(p_plan->>'ppv')::numeric then raise exception 'BV cannot exceed PPV';end if;
 if abs((p_plan->>'gp')::numeric-(p_plan->>'dp')::numeric*gplan)>.0001 or abs((p_plan->>'bp')::numeric-(p_plan->>'dp')::numeric*bplan)>.0001 then raise exception 'GP and BP must follow the configured DP plan split';end if;
 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;if levels not between 1 and 10 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–10; binary placement limit 1–30';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 tot:=0;for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;tot:=tot+rate;end loop;if tot>genbonus+.000000001 then raise exception 'Generation levels exceed the Generation bonus budget';end if;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid binary placement rate';end if;tot:=tot+rate;end loop;if tot>placement+.000000001 then raise exception 'Binary placement levels exceed their budget';end if;
 cfg:=cfg||jsonb_build_object('generation_plan_rate',gplan,'binary_plan_rate',bplan,'generation_bonus_rate',genbonus,'generation_manager_rate',genmanager,'generation_global_rate',genglobal,'single_line_cap',placement,'binary_pool_rate',pool,'binary_manager_rate',bmanager,'binary_global_rate',bglobal);
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement) values(p_code,old.version+1,old.display_name,(p_plan->>'base_value')::numeric,(p_plan->>'company_fee')::numeric,(p_plan->>'ppv')::numeric,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels) into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'generation_plan',jsonb_build_object('split',gplan,'generation',genbonus,'manager',genmanager,'global',genglobal),'binary_plan',jsonb_build_object('split',bplan,'pool',pool,'placement',placement,'manager',bmanager,'global',bglobal)));
 return cfg;
end$$;

create or replace function private.company_treasury_sources_before_ecommerce() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 with funding as(
  select 'order'::text typ,s.order_id id,s.bv base,s.dp,s.gp,s.bp,s.binary_reserve_mio reserve,o.rules_snapshot cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.dp,a.gp,a.bp,a.binary_reserve_mio,a.rules_snapshot from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ),spend as(
  select f.*,coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='direct'),0) direct_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='generation'),0) gen_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='single_line'),0) placement_paid from funding f
 )
 select typ,id,'generation_levels_pending','MIO',greatest(0,trunc(gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4)-gen_paid) from spend
 union all select typ,id,'generation_manager_pending','MIO',trunc(gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'generation_global_pending','MIO',trunc(gp*coalesce((cfg->>'generation_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'binary_placement_pending','MIO',greatest(0,trunc(bp*coalesce((cfg->>'single_line_cap')::numeric,.10),4)-placement_paid) from spend
 union all select typ,id,'binary_pool_pending','MIO',reserve from spend
 union all select typ,id,'binary_manager_pending','MIO',trunc(bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'binary_global_pending','MIO',trunc(bp*coalesce((cfg->>'binary_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'network_formula_leftover','MIO',greatest(0,dp-gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45)-gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05)-gp*coalesce((cfg->>'generation_global_rate')::numeric,.20)-bp*coalesce((cfg->>'binary_pool_rate')::numeric,.35)-bp*coalesce((cfg->>'single_line_cap')::numeric,.10)-bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05)-bp*coalesce((cfg->>'binary_global_rate')::numeric,.20)-direct_paid) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*300) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$$;

revoke all on function private.mlm_point_candidates(uuid,numeric,numeric,jsonb) from public,anon,authenticated;
revoke all on function private.mlm_candidates(uuid,numeric,jsonb),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb),private.snapshot_mlm_rules(),private.release_order_rewards(),private.guard_bonus_funding(),private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
grant execute on function public.admin_save_plan(text,jsonb,integer) to authenticated;


-- ===== schema/20261011193000_manual_binary_pool_admin.sql =====
-- Manual weekly Binary Pool Share settlement.
-- Automatic settlement is disabled; admins preview the week, enter the gross
-- value per completed share, and distribute after the seven-day period closes.

create or replace function public.admin_close_binary_cycle(
  p_cycle_code text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_manual_share_value numeric default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cycle uuid:=gen_random_uuid(); eligible numeric:=0; reserved_pool numeric:=0; pool numeric:=0; effective_rate numeric:=0;
 share_count bigint:=0; m record; gross numeric; member_pay numeric; remainder numeric; residual_recipient uuid; txn uuid; key text;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at or p_ends_at>now() then raise exception 'Choose a completed period with valid start/end'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
 if p_ends_at-p_starts_at<interval '7 days' then raise exception 'Binary pool can be distributed only after seven days'; end if;
 if p_manual_share_value is not null and p_manual_share_value<0 then raise exception 'Share value cannot be negative'; end if;
 if exists(select 1 from public.binary_cycles where status<>'reversed' and starts_at<p_ends_at and ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated') and ends_at>p_starts_at) then raise exception 'Close binary cycles in chronological order'; end if;
 if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated')) and p_starts_at<>(select max(ends_at) from public.binary_cycles where status in ('posted','unallocated')) then raise exception 'Start the cycle at the previous cycle end'; end if;
 select coalesce(sum(least(a.base_value,a.bv,a.payable_price-a.company_fee)),0),coalesce(sum(a.binary_reserve_mio),0) into eligible,reserved_pool
 from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at;
 eligible:=eligible+(select coalesce(sum(s.bv),0) from public.shopping_reward_events s where s.created_at>=p_starts_at and s.created_at<p_ends_at);
 reserved_pool:=reserved_pool+(select coalesce(sum(s.binary_reserve_mio),0) from public.shopping_reward_events s where s.created_at>=p_starts_at and s.created_at<p_ends_at);
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
 values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,p_timezone,eligible,case when eligible>0 then reserved_pool/eligible else coalesce((private.current_mlm_rules()->>'binary_pool_rate')::numeric,.35) end,0,'open');
 for m in
  with active_package as (
   select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,coalesce((private.current_mlm_rules()->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
   from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
   where a.status='approved' and a.activated_at<p_ends_at
   order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
  ), volume as (
   select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
   from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id
   where pl.point_type='BP' and ((a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at<p_ends_at) or s.created_at<p_ends_at) and pl.created_at<=now()
   group by pl.member_id
  ), consumed as (
   select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
   where c.status in ('posted','unallocated') and c.ends_at<=p_starts_at group by r.member_id
  )
  select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) l,greatest(coalesce(v.r,0)-coalesce(c.r,0),0) r
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 loop
  insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)
  values(cycle,m.member_id,m.package_code,m.package_version,m.l,m.r,floor(least(m.l,m.r)/50)::bigint,m.binary_entitlement,0,0,0,floor(least(m.l,m.r)/50)*50,floor(least(m.l,m.r)/50)*50,m.l-floor(least(m.l,m.r)/50)*50,m.r-floor(least(m.l,m.r)/50)*50,jsonb_build_object('qualification','active_package_and_full_share','reserved_pool',reserved_pool,'share_points_each_side',50,'manual_share_value',p_manual_share_value,'precision',4));
 end loop;
 select coalesce(sum(completed_shares),0) into share_count from public.binary_member_results where cycle_id=cycle;
 if share_count=0 then
  update public.binary_cycles set status='unallocated',pool_amount=0,total_completed_shares=0,closed_at=now() where id=cycle;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'reserved_pool',reserved_pool,'shares',0));
  return cycle;
 end if;
 pool:=case when p_manual_share_value is null then reserved_pool else trunc(p_manual_share_value*share_count,4) end;
 if pool>reserved_pool+.00000001 then raise exception 'Share value exceeds current binary pool wallet'; end if;
 effective_rate:=case when eligible>0 then pool/eligible else coalesce((private.current_mlm_rules()->>'binary_pool_rate')::numeric,.35) end;
 update public.binary_cycles set pool_amount=pool,pool_rate=effective_rate,total_completed_shares=share_count,gross_share_value=pool/share_count,status='frozen' where id=cycle;
 update public.binary_member_results set gross_amount=trunc(pool*completed_shares/share_count,4),company_retention=trunc(pool*completed_shares/share_count,4) where cycle_id=cycle;
 select pool-coalesce(sum(gross_amount),0) into remainder from public.binary_member_results where cycle_id=cycle;
 for residual_recipient in select member_id from public.binary_member_results where cycle_id=cycle and completed_shares>0 order by (pool*completed_shares/share_count-trunc(pool*completed_shares/share_count,4)) desc,member_id limit round(remainder*10000)::integer
 loop
  update public.binary_member_results set gross_amount=gross_amount+0.0001,company_retention=company_retention+0.0001 where cycle_id=cycle and member_id=residual_recipient;
 end loop;
 for m in select * from public.binary_member_results where cycle_id=cycle order by member_id loop
  gross:=m.gross_amount; member_pay:=trunc(gross*m.entitlement,4);
  update public.binary_member_results set member_amount=member_pay,company_retention=gross-member_pay where cycle_id=cycle and member_id=m.member_id;
  if member_pay>0 then
   key:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
   values(m.member_id,'binary_pool_share',cycle,gross,m.entitlement,gross,member_pay,'MIO','phase1-binary-pool-manual-v1',jsonb_build_object('completed_shares',m.completed_shares,'entitlement',m.entitlement,'gross_share_value',pool/share_count,'manual_share_value',p_manual_share_value,'member_amount',member_pay,'company_retention',gross-member_pay,'rounding','largest_remainder_4dp'),'posted',key) returning id into txn;
   update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing'; end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key) values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 if (select coalesce(sum(member_amount+company_retention),0) from public.binary_member_results where cycle_id=cycle)<>pool then raise exception 'Pool reconciliation failed'; end if;
 update public.binary_cycles set status='posted',closed_at=now() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'reserved_pool',reserved_pool,'pool',pool,'shares',share_count,'manual_share_value',p_manual_share_value,'rounding','largest_remainder_4dp'));
 return cycle;
end;
$$;

create or replace function public.admin_close_binary_cycle(p_cycle_code text,p_starts_at timestamptz,p_ends_at timestamptz,p_timezone text)
returns uuid language sql security definer set search_path='' as $$select public.admin_close_binary_cycle(p_cycle_code,p_starts_at,p_ends_at,p_timezone,null::numeric)$$;

create or replace function public.admin_binary_pool_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
declare admin_id uuid:=auth.uid(); earliest_event timestamptz; last_end timestamptz; period_start timestamptz; period_end timestamptz; total_wallet numeric:=0; week_pool numeric:=0; last_distributed numeric:=0; total_shares bigint:=0; package_json jsonb:='[]'::jsonb;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 select min(event_at) into earliest_event from(select a.activated_at event_at from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' union all select s.created_at from public.shopping_reward_events s) events;
 select max(ends_at) into last_end from public.binary_cycles where status in('posted','unallocated');
 period_start:=coalesce(last_end,date_trunc('week',coalesce(earliest_event,now()) at time zone 'Asia/Karachi') at time zone 'Asia/Karachi');
 period_end:=period_start+interval '7 days';
 select greatest(0,coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV'),0)+coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events),0)-coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated')),0)) into total_wallet;
 select coalesce(sum(binary_reserve_mio),0) into week_pool from(select a.binary_reserve_mio from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>=period_start and a.activated_at<period_end union all select s.binary_reserve_mio from public.shopping_reward_events s where s.created_at>=period_start and s.created_at<period_end) x;
 with active_package as (
  select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,coalesce((private.current_mlm_rules()->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
  from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
  where a.status='approved' and a.activated_at<period_end
  order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
 ), volume as (
  select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
  from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id
  where pl.point_type='BP' and ((a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at<period_end) or s.created_at<period_end) and pl.created_at<=now()
  group by pl.member_id
 ), consumed as (
  select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where c.status in('posted','unallocated') and c.ends_at<=period_start group by r.member_id
 ), shares as (
  select ap.package_code,floor(least(greatest(coalesce(v.l,0)-coalesce(c.l,0),0),greatest(coalesce(v.r,0)-coalesce(c.r,0),0))/50)::bigint completed from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 )
 select coalesce(sum(shares),0),coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb) into total_shares,package_json from (select package_code,sum(completed) shares from shares group by package_code having sum(completed)>0) p;
 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles where status='posted' order by ends_at desc limit 1;
 return jsonb_build_object('total_pool_wallet',total_wallet,'this_week_pool',week_pool,'last_week_distributed',last_distributed,'total_shares',coalesce(total_shares,0),'shares_by_package',package_json,'period_start',period_start,'period_end',period_end,'can_distribute',period_end<=now() and coalesce(total_shares,0)>0 and week_pool>0,'default_share_value',case when coalesce(total_shares,0)>0 then trunc(week_pool/total_shares,4) else 0 end,'next_cycle_code','MANUAL-'||to_char(period_start at time zone 'Asia/Karachi','IYYY-"W"IW'));
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb; cycle uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 d:=public.admin_binary_pool_dashboard();
 if coalesce((d->>'can_distribute')::boolean,false) is not true then raise exception 'Binary pool is not ready for distribution yet'; end if;
 cycle:=public.admin_close_binary_cycle(d->>'next_cycle_code',(d->>'period_start')::timestamptz,(d->>'period_end')::timestamptz,'Asia/Karachi',p_share_value);
 return jsonb_build_object('cycle_id',cycle,'cycle_code',d->>'next_cycle_code','share_value',p_share_value);
end;
$$;

create or replace function private.run_automatic_binary_pool()
returns integer language plpgsql security definer set search_path='' as $$begin return 0; end$$;

do $$begin
 if to_regclass('cron.job') is not null then
  perform cron.unschedule(jobid) from cron.job where jobname='mio-automatic-binary-pool';
 end if;
exception when others then null;
end$$;

revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) from public,anon;
revoke all on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text,numeric) from public,anon;
revoke all on function public.admin_binary_pool_dashboard() from public,anon;
revoke all on function public.admin_distribute_binary_pool(numeric) from public,anon;
grant execute on function public.admin_close_binary_cycle(text,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.admin_binary_pool_dashboard() to authenticated;
grant execute on function public.admin_distribute_binary_pool(numeric) to authenticated;
revoke all on function private.run_automatic_binary_pool() from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261011204000_binary_pool_collapsible_share_rule.sql =====
-- Binary pool admin control: editable BP threshold per completed share.

create or replace function public.admin_set_binary_share_points(p_points_each_side numeric)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare cfg jsonb; v integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_points_each_side is null or p_points_each_side<=0 or p_points_each_side>1000000 then raise exception 'Enter valid BP points per side'; end if;
 perform pg_advisory_xact_lock(hashtextextended('edit-binary-share-points',0));
 cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 cfg:=jsonb_set(cfg,'{binary_share_points_each_side}',to_jsonb(trunc(p_points_each_side,4)),true);
 cfg:=jsonb_set(cfg,'{version}',to_jsonb(v+1),true);
 update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'BINARY_SHARE_POINTS_SAVED','mlm_rules',jsonb_build_object('points_each_side',trunc(p_points_each_side,4),'version',v+1));
 return cfg;
end;
$$;

create or replace function public.admin_close_binary_cycle(
  p_cycle_code text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_manual_share_value numeric default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cycle uuid:=gen_random_uuid(); eligible numeric:=0; reserved_pool numeric:=0; pool numeric:=0; effective_rate numeric:=0;
 share_count bigint:=0; m record; gross numeric; member_pay numeric; remainder numeric; residual_recipient uuid; txn uuid; key text; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 cfg:=private.current_mlm_rules();share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then raise exception 'Binary share points rule is invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at or p_ends_at>now() then raise exception 'Choose a completed period with valid start/end'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
 if p_ends_at-p_starts_at<interval '7 days' then raise exception 'Binary pool can be distributed only after seven days'; end if;
 if p_manual_share_value is not null and p_manual_share_value<0 then raise exception 'Share price cannot be negative'; end if;
 if exists(select 1 from public.binary_cycles where status<>'reversed' and starts_at<p_ends_at and ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated') and ends_at>p_starts_at) then raise exception 'Close binary cycles in chronological order'; end if;
 if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;
 if exists(select 1 from public.binary_cycles where status in ('posted','unallocated')) and p_starts_at<>(select max(ends_at) from public.binary_cycles where status in ('posted','unallocated')) then raise exception 'Start the cycle at the previous cycle end'; end if;
 select coalesce(sum(least(a.base_value,a.bv,a.payable_price-a.company_fee)),0),coalesce(sum(a.binary_reserve_mio),0) into eligible,reserved_pool
 from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at;
 eligible:=eligible+(select coalesce(sum(s.bv),0) from public.shopping_reward_events s where s.created_at>=p_starts_at and s.created_at<p_ends_at);
 reserved_pool:=reserved_pool+(select coalesce(sum(s.binary_reserve_mio),0) from public.shopping_reward_events s where s.created_at>=p_starts_at and s.created_at<p_ends_at);
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
 values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,p_timezone,eligible,case when eligible>0 then reserved_pool/eligible else coalesce((cfg->>'binary_pool_rate')::numeric,.35) end,0,'open');
 for m in
  with active_package as (
   select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,coalesce((cfg->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
   from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
   where a.status='approved' and a.activated_at<p_ends_at
   order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
  ), volume as (
   select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
   from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id
   where pl.point_type='BP' and ((a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at<p_ends_at) or s.created_at<p_ends_at) and pl.created_at<=now()
   group by pl.member_id
  ), consumed as (
   select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
   where c.status in ('posted','unallocated') and c.ends_at<=p_starts_at group by r.member_id
  )
  select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) l,greatest(coalesce(v.r,0)-coalesce(c.r,0),0) r
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 loop
  insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)
  values(cycle,m.member_id,m.package_code,m.package_version,m.l,m.r,floor(least(m.l,m.r)/share_points)::bigint,m.binary_entitlement,0,0,0,floor(least(m.l,m.r)/share_points)*share_points,floor(least(m.l,m.r)/share_points)*share_points,m.l-floor(least(m.l,m.r)/share_points)*share_points,m.r-floor(least(m.l,m.r)/share_points)*share_points,jsonb_build_object('qualification','active_package_and_full_share','reserved_pool',reserved_pool,'share_points_each_side',share_points,'manual_share_value',p_manual_share_value,'precision',4));
 end loop;
 select coalesce(sum(completed_shares),0) into share_count from public.binary_member_results where cycle_id=cycle;
 if share_count=0 then
  update public.binary_cycles set status='unallocated',pool_amount=0,total_completed_shares=0,closed_at=now() where id=cycle;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'reserved_pool',reserved_pool,'shares',0,'share_points_each_side',share_points));
  return cycle;
 end if;
 pool:=case when p_manual_share_value is null then reserved_pool else trunc(p_manual_share_value*share_count,4) end;
 if pool>reserved_pool+.00000001 then raise exception 'Share price exceeds current binary pool wallet'; end if;
 effective_rate:=case when eligible>0 then pool/eligible else coalesce((cfg->>'binary_pool_rate')::numeric,.35) end;
 update public.binary_cycles set pool_amount=pool,pool_rate=effective_rate,total_completed_shares=share_count,gross_share_value=pool/share_count,status='frozen' where id=cycle;
 update public.binary_member_results set gross_amount=trunc(pool*completed_shares/share_count,4),company_retention=trunc(pool*completed_shares/share_count,4) where cycle_id=cycle;
 select pool-coalesce(sum(gross_amount),0) into remainder from public.binary_member_results where cycle_id=cycle;
 for residual_recipient in select member_id from public.binary_member_results where cycle_id=cycle and completed_shares>0 order by (pool*completed_shares/share_count-trunc(pool*completed_shares/share_count,4)) desc,member_id limit round(remainder*10000)::integer
 loop
  update public.binary_member_results set gross_amount=gross_amount+0.0001,company_retention=company_retention+0.0001 where cycle_id=cycle and member_id=residual_recipient;
 end loop;
 for m in select * from public.binary_member_results where cycle_id=cycle order by member_id loop
  gross:=m.gross_amount; member_pay:=trunc(gross*m.entitlement,4);
  update public.binary_member_results set member_amount=member_pay,company_retention=gross-member_pay where cycle_id=cycle and member_id=m.member_id;
  if member_pay>0 then
   key:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
   values(m.member_id,'binary_pool_share',cycle,gross,m.entitlement,gross,member_pay,'MIO','phase1-binary-pool-manual-v2',jsonb_build_object('completed_shares',m.completed_shares,'entitlement',m.entitlement,'gross_share_value',pool/share_count,'share_points_each_side',share_points,'manual_share_value',p_manual_share_value,'member_amount',member_pay,'company_retention',gross-member_pay,'rounding','largest_remainder_4dp'),'posted',key) returning id into txn;
   update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing'; end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key) values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 if (select coalesce(sum(member_amount+company_retention),0) from public.binary_member_results where cycle_id=cycle)<>pool then raise exception 'Pool reconciliation failed'; end if;
 update public.binary_cycles set status='posted',closed_at=now() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'reserved_pool',reserved_pool,'pool',pool,'shares',share_count,'share_points_each_side',share_points,'manual_share_value',p_manual_share_value,'rounding','largest_remainder_4dp'));
 return cycle;
end;
$$;

create or replace function public.admin_binary_pool_dashboard()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare admin_id uuid:=auth.uid(); earliest_event timestamptz; last_end timestamptz; period_start timestamptz; period_end timestamptz; total_wallet numeric:=0; week_pool numeric:=0; last_distributed numeric:=0; total_shares bigint:=0; package_json jsonb:='[]'::jsonb; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 cfg:=private.current_mlm_rules();share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then share_points:=50; end if;
 select min(event_at) into earliest_event from(select a.activated_at event_at from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' union all select s.created_at from public.shopping_reward_events s) events;
 select max(ends_at) into last_end from public.binary_cycles where status in('posted','unallocated');
 period_start:=coalesce(last_end,date_trunc('week',coalesce(earliest_event,now()) at time zone 'Asia/Karachi') at time zone 'Asia/Karachi');
 period_end:=period_start+interval '7 days';
 select greatest(0,coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV'),0)+coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events),0)-coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated')),0)) into total_wallet;
 select coalesce(sum(binary_reserve_mio),0) into week_pool from(select a.binary_reserve_mio from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>=period_start and a.activated_at<period_end union all select s.binary_reserve_mio from public.shopping_reward_events s where s.created_at>=period_start and s.created_at<period_end) x;
 with active_package as (
  select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,coalesce((cfg->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
  from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
  where a.status='approved' and a.activated_at<period_end
  order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
 ), volume as (
  select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
  from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id
  where pl.point_type='BP' and ((a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at<period_end) or s.created_at<period_end) and pl.created_at<=now()
  group by pl.member_id
 ), consumed as (
  select r.member_id,sum(r.consumed_left) l,sum(r.consumed_right) r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where c.status in('posted','unallocated') and c.ends_at<=period_start group by r.member_id
 ), shares as (
  select ap.package_code,floor(least(greatest(coalesce(v.l,0)-coalesce(c.l,0),0),greatest(coalesce(v.r,0)-coalesce(c.r,0),0))/share_points)::bigint completed from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 )
 select coalesce(sum(shares),0),coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb) into total_shares,package_json from (select package_code,sum(completed) shares from shares group by package_code having sum(completed)>0) p;
 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles where status='posted' order by ends_at desc limit 1;
 return jsonb_build_object('total_pool_wallet',total_wallet,'this_week_pool',week_pool,'last_week_distributed',last_distributed,'total_shares',coalesce(total_shares,0),'shares_by_package',package_json,'share_points_each_side',share_points,'period_start',period_start,'period_end',period_end,'can_distribute',period_end<=now() and coalesce(total_shares,0)>0 and week_pool>0,'default_share_value',case when coalesce(total_shares,0)>0 then trunc(week_pool/total_shares,4) else 0 end,'next_cycle_code','MANUAL-'||to_char(period_start at time zone 'Asia/Karachi','IYYY-"W"IW'));
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare d jsonb; cycle uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 d:=public.admin_binary_pool_dashboard();
 if coalesce((d->>'can_distribute')::boolean,false) is not true then raise exception 'Binary pool is not ready for distribution yet'; end if;
 cycle:=public.admin_close_binary_cycle(d->>'next_cycle_code',(d->>'period_start')::timestamptz,(d->>'period_end')::timestamptz,'Asia/Karachi',p_share_value);
 return jsonb_build_object('cycle_id',cycle,'cycle_code',d->>'next_cycle_code','share_value',p_share_value,'share_points_each_side',d->>'share_points_each_side');
end;
$$;

revoke all on function public.admin_set_binary_share_points(numeric) from public,anon;
revoke all on function public.admin_binary_pool_dashboard() from public,anon;
revoke all on function public.admin_distribute_binary_pool(numeric) from public,anon;
grant execute on function public.admin_set_binary_share_points(numeric) to authenticated;
grant execute on function public.admin_binary_pool_dashboard() to authenticated;
grant execute on function public.admin_distribute_binary_pool(numeric) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261011210000_dp_generation_level_qualification.sql =====
-- DP qualification: generation levels open only when package, direct-active count
-- and direct DP thresholds are all satisfied.

create or replace function private.direct_dp_summary(p_member uuid)
returns table(active_directs integer,total_dp numeric)
language sql stable security definer set search_path=''
as $$
 select
  count(distinct mp.user_id)::integer,
  coalesce(sum(a.dp),0)::numeric
 from public.member_profiles mp
 left join public.package_activations a on a.member_id=mp.user_id and a.status='approved'
 where mp.sponsor_id=p_member and mp.status='active';
$$;

create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer
language sql stable security definer set search_path=''
as $$
 with pkg as (
  select coalesce(private.current_package_code(p_member),'BASIC_1') code
 ), plan as (
  select coalesce((p_cfg->'plans'->pkg.code->>'max_generations')::integer,0) package_levels from pkg
 ), d as (
  select * from private.direct_dp_summary(p_member)
 ), gate as (
  select case
   when active_directs>=5 and total_dp>=100 then 10
   when active_directs>=4 and total_dp>=80 then 8
   when active_directs>=3 and total_dp>=60 then 6
   when active_directs>=2 and total_dp>=40 then 4
   when active_directs>=1 and total_dp>=20 then 2
   else 0
  end direct_dp_levels from d
 )
 select least((select package_levels from plan),(select direct_dp_levels from gate));
$$;

create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,private.package_eligible(u.id) eligible,private.generation_levels_by_dp(u.id,cfg) open_levels
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*coalesce((plan->>'direct_rate')::numeric,0)
       else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved
 where depth=1 or (eligible and depth<=open_levels);
$$;

revoke all on function private.direct_dp_summary(uuid),private.generation_levels_by_dp(uuid,jsonb),private.mlm_point_candidates(uuid,numeric,numeric,jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261012170500_free_members_outside_binary.sql =====
-- Free registrations remain visible in the sponsor/generation relationship,
-- but cannot sponsor a team or occupy a binary position until a plan is active.
create or replace function private.enforce_package_membership()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sponsor_id is not null and (tg_op = 'INSERT' or new.sponsor_id is distinct from old.sponsor_id)
     and not private.package_eligible(new.sponsor_id)
     and not exists (select 1 from public.user_roles where user_id = new.sponsor_id and role = 'admin') then
    raise exception 'This referral is locked. The sponsor must activate a plan before building a team';
  end if;
  if new.status = 'active'
     and not exists (select 1 from public.user_roles where user_id = new.user_id and role = 'admin')
     and not exists (select 1 from public.package_activations where member_id = new.user_id and status = 'approved') then
    new.status := 'inactive';
  end if;
  return new;
end;
$$;

create or replace function private.place_signup_binary()
returns trigger language plpgsql security definer set search_path = '' as $$
declare side text;
begin
  select raw_user_meta_data ->> 'referral_side' into side from auth.users where id = new.user_id;
  if private.package_eligible(new.user_id) and new.sponsor_id is not null and side is not null then
    perform private.place_outermost(new.user_id, new.sponsor_id, upper(side));
  end if;
  return new;
end;
$$;

create or replace function private.place_binary_after_activation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare sponsor uuid; side text; company uuid;
begin
  if new.status <> 'approved' or not private.package_eligible(new.member_id)
     or exists (select 1 from public.binary_placements where member_id = new.member_id) then return new; end if;
  if exists(select 1 from public.user_roles where user_id=new.member_id and role='admin') then return new; end if;
  select company_id into company from private.network_foundation where singleton and founder_id=new.member_id;
  if company is not null then
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
    values(new.member_id,null,null,company) on conflict(member_id) do nothing;
    return new;
  end if;
  select m.sponsor_id, u.raw_user_meta_data ->> 'referral_side' into sponsor, side
  from public.member_profiles m join auth.users u on u.id = m.user_id where m.user_id = new.member_id;
  if sponsor is not null and side is not null then perform private.place_outermost(new.member_id, sponsor, upper(side)); end if;
  return new;
end;
$$;
drop trigger if exists ab0_place_binary_after_activation on public.package_activations;
create trigger ab0_place_binary_after_activation after insert or update of status on public.package_activations
for each row execute function private.place_binary_after_activation();

create or replace function public.lookup_side_referral(p_code text)
returns table(member_code text, full_name text, placement_side text)
language sql stable security definer set search_path = '' as $$
  select m.member_code,m.full_name,case right(upper(trim(p_code)),2) when '-L' then 'LEFT' when '-R' then 'RIGHT' else null end
  from public.member_profiles m
  where (upper(m.referral_code)=regexp_replace(upper(trim(p_code)),'-[LR]$','') or upper(m.member_code)=regexp_replace(upper(trim(p_code)),'-[LR]$',''))
    and private.package_eligible(m.user_id)
    and not exists(select 1 from public.user_roles r where r.user_id=m.user_id and r.role='admin');
$$;
revoke all on function private.place_binary_after_activation() from public,anon,authenticated;
revoke all on function public.lookup_side_referral(text) from public,anon;
grant execute on function public.lookup_side_referral(text) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261012224000_complete_marketplace_categories.sql =====
-- Keep the Company registry usable in a clean pre-founder state.
alter table private.network_foundation alter column founder_id drop not null;

-- Complete marketplace category catalog. Existing product category names remain valid.
do $$
declare
  company uuid;
  next_version integer;
  categories jsonb := '[
    {"name":"Electronics & Accessories","slug":"electronics","icon":"electronics"},
    {"name":"Mobiles & Tablets","slug":"mobiles-tablets","icon":"electronics"},
    {"name":"Computers & Gaming","slug":"computers-gaming","icon":"electronics"},
    {"name":"TV, Audio & Cameras","slug":"tv-audio-cameras","icon":"electronics"},
    {"name":"Women’s Fashion","slug":"womens-fashion","icon":"womens-fashion"},
    {"name":"Men’s Fashion","slug":"mens-fashion","icon":"mens-fashion"},
    {"name":"Kids & Baby","slug":"kids-baby","icon":"toys"},
    {"name":"Shoes & Footwear","slug":"shoes-footwear","icon":"mens-fashion"},
    {"name":"Bags & Luggage","slug":"bags-luggage","icon":"womens-fashion"},
    {"name":"Jewellery & Watches","slug":"jewellery-watches","icon":"jewellery"},
    {"name":"Beauty & Personal Care","slug":"beauty-personal-care","icon":"beauty"},
    {"name":"Skincare","slug":"skincare","icon":"skincare"},
    {"name":"Hair & beard care","slug":"hair-beard-care","icon":"hair-beard-care"},
    {"name":"Skincare bundles","slug":"skincare-bundles","icon":"skincare-bundles"},
    {"name":"Health & Wellness","slug":"health-wellness","icon":"health"},
    {"name":"Home & Living","slug":"home-living","icon":"home-living"},
    {"name":"Kitchen & Dining","slug":"kitchen-dining","icon":"home-living"},
    {"name":"Furniture & Decor","slug":"furniture-decor","icon":"home-living"},
    {"name":"Grocery & Food","slug":"grocery-food","icon":"grocery"},
    {"name":"Sports & Outdoors","slug":"sports-outdoors","icon":"sports"},
    {"name":"Toys & Games","slug":"toys-games","icon":"toys"},
    {"name":"Books & Stationery","slug":"books-stationery","icon":"books"},
    {"name":"Automotive & Motorbike","slug":"automotive-motorbike","icon":"automotive"},
    {"name":"Tools & Home Improvement","slug":"tools-home-improvement","icon":"home-living"},
    {"name":"Pet Supplies","slug":"pet-supplies","icon":"health"},
    {"name":"Office & Business Supplies","slug":"office-business-supplies","icon":"books"},
    {"name":"Travel & Outdoor","slug":"travel-outdoor","icon":"sports"}
  ]'::jsonb;
begin
  select m.user_id into company
  from public.member_profiles m
  join public.user_roles r on r.user_id=m.user_id and r.role='admin'
  order by m.created_at
  limit 1;

  select coalesce(max(version),0)+1 into next_version
  from public.system_config
  where config_key='MARKETPLACE_CATEGORIES';

  update public.system_config
  set effective_to=clock_timestamp()
  where config_key='MARKETPLACE_CATEGORIES' and effective_to is null;

  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
  values('MARKETPLACE_CATEGORIES',next_version,categories,clock_timestamp(),company);
end
$$;


-- ===== schema/20261012230000_dynamic_generation_qualification.sql =====
-- Generation earnings require the selected plan, its active-direct target and its DP target.
do $$
declare cfg jsonb; next_version integer; code text; levels integer;
begin
  select config_value into cfg
  from public.system_config
  where config_key='MLM_PLANS' and effective_to is null
  order by version desc limit 1 for update;

  next_version:=coalesce((cfg->>'version')::integer,0)+1;
  for code in select jsonb_object_keys(cfg->'plans') loop
    levels:=coalesce((cfg->'plans'->code->>'max_generations')::integer,0);
    cfg:=jsonb_set(cfg,array['plans',code,'generation_required_directs'],to_jsonb(ceil(levels/2.0)::integer),true);
    cfg:=jsonb_set(cfg,array['plans',code,'generation_required_dp'],to_jsonb((levels*10)::numeric),true);
  end loop;
  cfg:=jsonb_set(cfg,'{version}',to_jsonb(next_version),true);

  update public.system_config set effective_to=clock_timestamp()
  where config_key='MLM_PLANS' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
  values('MLM_PLANS',next_version,cfg,clock_timestamp(),
    (select user_id from public.user_roles where role='admin' order by user_id limit 1));
end
$$;

create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer
language sql stable security definer set search_path=''
as $$
 with plan as (
  select p,
   coalesce((p->>'max_generations')::integer,0) package_levels,
   coalesce((p->>'generation_required_directs')::integer,ceil(coalesce((p->>'max_generations')::numeric,0)/2)::integer) required_directs,
   coalesce((p->>'generation_required_dp')::numeric,coalesce((p->>'max_generations')::numeric,0)*10) required_dp
  from (select p_cfg->'plans'->coalesce(private.current_package_code(p_member),'BASIC_1') p) q
 ), d as (
  select * from private.direct_dp_summary(p_member)
 )
 select case when d.active_directs>=plan.required_directs and d.total_dp>=plan.required_dp
             then plan.package_levels else 0 end
 from plan cross join d;
$$;

create or replace function public.admin_save_plan(p_code text,p_plan jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;required_directs integer;required_dp numeric;rate numeric;tot numeric;key text;gplan numeric;bplan numeric;genbonus numeric;genmanager numeric;genglobal numeric;placement numeric;pool numeric;bmanager numeric;bglobal numeric;
begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;perform private.require_recent_totp();perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;
 foreach key in array array['generation_plan_rate','binary_plan_rate','generation_bonus_rate','generation_manager_rate','generation_global_rate','single_line_cap','binary_pool_rate','binary_manager_rate','binary_global_rate'] loop if jsonb_typeof(p_plan->key)<>'number' then raise exception 'Missing numeric budget: %',key;end if;end loop;
 gplan:=(p_plan->>'generation_plan_rate')::numeric;bplan:=(p_plan->>'binary_plan_rate')::numeric;genbonus:=(p_plan->>'generation_bonus_rate')::numeric;genmanager:=(p_plan->>'generation_manager_rate')::numeric;genglobal:=(p_plan->>'generation_global_rate')::numeric;placement:=(p_plan->>'single_line_cap')::numeric;pool:=(p_plan->>'binary_pool_rate')::numeric;bmanager:=(p_plan->>'binary_manager_rate')::numeric;bglobal:=(p_plan->>'binary_global_rate')::numeric;
 if least(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)<0 or greatest(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)>1 then raise exception 'All percentages must be between 0 and 100';end if;
 if abs(gplan+bplan-1)>.000000001 then raise exception 'Generation Plan and Binary Plan must total exactly 100 percent';end if;if genbonus+genmanager+genglobal>1.000000001 then raise exception 'Generation breakdown exceeds 100 percent of GP';end if;if placement+pool+bmanager+bglobal>1.000000001 then raise exception 'Binary breakdown exceeds 100 percent of BP';end if;
 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','company_fee','ppv','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','generation_required_directs','generation_required_dp','single_line_levels'] loop if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 then raise exception 'Invalid plan value: %',key;end if;end loop;
 if (p_plan->>'base_value')::numeric<=0 or (p_plan->>'ppv')::numeric<=0 or (p_plan->>'bv')::numeric>(p_plan->>'base_value')::numeric or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;if (p_plan->>'bv')::numeric>(p_plan->>'ppv')::numeric then raise exception 'BV cannot exceed PPV';end if;
 if abs((p_plan->>'gp')::numeric-(p_plan->>'dp')::numeric*gplan)>.0001 or abs((p_plan->>'bp')::numeric-(p_plan->>'dp')::numeric*bplan)>.0001 then raise exception 'GP and BP must follow the configured DP plan split';end if;
 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;required_directs:=(p_plan->>'generation_required_directs')::integer;required_dp:=(p_plan->>'generation_required_dp')::numeric;
 if levels not between 1 and 10 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–10; binary placement limit 1–30';end if;
 if required_directs not between 0 and 100 or (p_plan->>'generation_required_directs')::numeric<>required_directs or required_dp<0 then raise exception 'Generation qualification requires a whole direct-member count and non-negative DP';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 tot:=0;for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;tot:=tot+rate;end loop;if tot>genbonus+.000000001 then raise exception 'Generation levels exceed the Generation bonus budget';end if;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid binary placement rate';end if;tot:=tot+rate;end loop;if tot>placement+.000000001 then raise exception 'Binary placement levels exceed their budget';end if;
 cfg:=cfg||jsonb_build_object('generation_plan_rate',gplan,'binary_plan_rate',bplan,'generation_bonus_rate',genbonus,'generation_manager_rate',genmanager,'generation_global_rate',genglobal,'single_line_cap',placement,'binary_pool_rate',pool,'binary_manager_rate',bmanager,'binary_global_rate',bglobal);
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement) values(p_code,old.version+1,old.display_name,(p_plan->>'base_value')::numeric,(p_plan->>'company_fee')::numeric,(p_plan->>'ppv')::numeric,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels,'generation_required_directs',required_directs,'generation_required_dp',required_dp) into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'generation_plan',jsonb_build_object('split',gplan,'generation',genbonus,'manager',genmanager,'global',genglobal),'binary_plan',jsonb_build_object('split',bplan,'pool',pool,'placement',placement,'manager',bmanager,'global',bglobal)));
 return cfg;
end$$;

revoke all on function private.generation_levels_by_dp(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.admin_save_plan(text,jsonb,integer) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261013020000_partial_package_upgrades.sql =====
-- Package upgrades are incremental: a member pays and earns only the difference
-- between their current active package and the target higher package.

create or replace function public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  member uuid := (select auth.uid());
  p public.package_versions%rowtype;
  current_p public.package_versions%rowtype;
  current_code text;
  activation uuid;
  new_balance numeric(20,4);
  due_base numeric(14,2);
  due_fee numeric(14,2);
  due_payable numeric(14,2);
  due_ppv numeric(14,4);
  due_bv numeric(14,4);
  due_dp numeric(14,4);
  due_gp numeric(14,4);
  due_bp numeric(14,4);
  due_brp numeric(14,4);
begin
  if member is null then raise exception 'Authentication required'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 then raise exception 'Invalid idempotency key'; end if;
  if not exists(select 1 from public.member_profiles where user_id=member) then
    raise exception 'Member account required';
  end if;

  select * into p from public.package_versions where package_code=p_package_code and is_active
    and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
  if p.package_code is null then raise exception 'Package not available'; end if;

  perform pg_advisory_xact_lock(hashtextextended('package-member:'||member::text,0));
  select id into activation from public.package_activations where member_id=member and idempotency_key=member::text||':'||p_idempotency_key;
  if activation is not null then return activation; end if;

  current_code := private.current_package_code(member);
  if current_code is not null then
    select * into current_p from public.package_versions where package_code=current_code order by version desc limit 1;
    if p.payable_price <= coalesce(current_p.payable_price,0) then raise exception 'Choose a higher package tier'; end if;
  end if;

  due_base := p.base_value - coalesce(current_p.base_value,0);
  due_fee := p.company_fee - coalesce(current_p.company_fee,0);
  due_payable := p.payable_price - coalesce(current_p.payable_price,0);
  due_ppv := p.ppv - coalesce(current_p.ppv,0);
  due_bv := p.bv - coalesce(current_p.bv,0);
  due_dp := p.dp - coalesce(current_p.dp,0);
  due_gp := p.gp - coalesce(current_p.gp,0);
  due_bp := p.bp - coalesce(current_p.bp,0);
  due_brp := p.brp - coalesce(current_p.brp,0);
  if due_payable <= 0 or due_base <= 0 or due_ppv <= 0 then raise exception 'Choose a higher package tier'; end if;

  update public.mio_wallet_accounts set balance=balance-due_payable, updated_at=now()
    where member_id=member and balance >= due_payable returning balance into new_balance;
  if new_balance is null then raise exception 'Insufficient MIO Points'; end if;

  activation := gen_random_uuid();
  insert into public.package_activations(
    id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,
    base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,
    status,activated_at,approved_by,idempotency_key)
  values(activation,member,p.package_code,p.version,'MIO_POINTS',p_idempotency_key,'MIO',due_payable,1,
    due_base,due_fee,due_payable,due_ppv,due_bv,due_dp,due_gp,due_bp,due_brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
    'approved',now(),member,member::text||':'||p_idempotency_key);

  insert into public.mio_ledger(member_id,amount,action,activation_id,idempotency_key)
    values(member,-due_payable,'package_activation',activation,member::text||':'||p_idempotency_key || ':mio');
  insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
    values(member,'PPV',due_ppv,activation,'credit',member::text||':'||p_idempotency_key || ':ppv');
  perform private.credit_activation_bonuses(activation);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,
      jsonb_build_object('package_code',p.package_code,'upgrade_due_mio',due_payable,'ppv_credited',due_ppv,'previous_package',current_code));
  return activation;
end;
$function$;

revoke all on function public.activate_package_with_mio(text,text) from public, anon;
grant execute on function public.activate_package_with_mio(text,text) to authenticated;

create or replace function private.activate_next_ppv_package(p_member_id uuid, p_order_id uuid, p_cumulative_ppv numeric)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  rank_code text[] := array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2'];
  current_code text;
  current_rank integer;
  current_p public.package_versions%rowtype;
  i integer;
  p public.package_versions%rowtype;
  aid uuid;
  count_activated integer := 0;
  id_key text;
  due_base numeric(14,2);
  due_fee numeric(14,2);
  due_payable numeric(14,2);
  due_ppv numeric(14,4);
  due_bv numeric(14,4);
  due_dp numeric(14,4);
  due_gp numeric(14,4);
  due_bp numeric(14,4);
  due_brp numeric(14,4);
begin
  perform pg_advisory_xact_lock(hashtextextended('package-member:'||p_member_id::text,0));
  current_code := private.current_package_code(p_member_id);
  current_rank := array_position(rank_code,current_code);
  select coalesce(sum(amount),0) into p_cumulative_ppv from public.point_ledger where member_id=p_member_id and point_type='PPV';
  if current_code='PREMIUM' then return 0; end if;
  if current_rank is null then
    current_rank := 0;
  else
    select * into current_p from public.package_versions where package_code=current_code order by version desc limit 1;
  end if;

  for i in current_rank+1..4 loop
    select * into p from public.package_versions where package_code=rank_code[i] and is_active
      and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
    if p.package_code is null or p_cumulative_ppv < p.ppv then exit; end if;
    id_key := 'ppv:' || p_order_id::text || ':' || rank_code[i];
    if exists(select 1 from public.package_activations where idempotency_key=id_key) then
      current_p := p;
      continue;
    end if;

    due_base := p.base_value - coalesce(current_p.base_value,0);
    due_fee := p.company_fee - coalesce(current_p.company_fee,0);
    due_payable := p.payable_price - coalesce(current_p.payable_price,0);
    due_ppv := p.ppv - coalesce(current_p.ppv,0);
    due_bv := p.bv - coalesce(current_p.bv,0);
    due_dp := p.dp - coalesce(current_p.dp,0);
    due_gp := p.gp - coalesce(current_p.gp,0);
    due_bp := p.bp - coalesce(current_p.bp,0);
    due_brp := p.brp - coalesce(current_p.brp,0);
    if due_payable <= 0 or due_base <= 0 or due_ppv <= 0 then
      current_p := p;
      continue;
    end if;

    aid := gen_random_uuid();
    insert into public.package_activations(
      id,member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,
      direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
    values(aid,p_member_id,p.package_code,p.version,'SHOPPING_PPV',p_order_id::text,due_base,due_fee,due_payable,
      due_ppv,due_bv,due_dp,due_gp,due_bp,due_brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
      'approved',now(),null,id_key);
    perform private.credit_activation_bonuses(aid);
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(p_member_id,'PACKAGE_AUTO_ACTIVATED_PPV','package_activation',aid,
        jsonb_build_object('order_id',p_order_id,'package_code',p.package_code,'ppv_balance',p_cumulative_ppv,'incremental_ppv',due_ppv));
    current_p := p;
    count_activated := count_activated+1;
  end loop;
  return count_activated;
end;
$function$;

revoke all on function private.activate_next_ppv_package(uuid,uuid,numeric) from public, anon, authenticated;


-- ===== schema/20261013033000_guest_checkout.sql =====
-- Guest buyers can place COD orders without becoming network members.
-- Affiliate attribution is still snapshotted and rewards remain delivery/payment gated.
alter table public.orders alter column buyer_id drop not null;
alter table public.orders add column if not exists guest_email text;
alter table public.orders add column if not exists guest_access_token_hash text;
alter table public.orders add constraint orders_guest_identity_check check (
  buyer_id is not null or (
    guest_email is not null and
    guest_access_token_hash is not null and
    length(guest_email) between 5 and 254
  )
);
create index if not exists orders_guest_email_time_idx on public.orders(lower(guest_email),created_at desc) where buyer_id is null;

create or replace function public.place_guest_affiliate_order(
  p_items jsonb,
  p_shipping_name text,
  p_shipping_phone text,
  p_shipping_address text,
  p_shipping_city text,
  p_guest_email text,
  p_idempotency_key text,
  p_access_token text,
  p_affiliate_code text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  oid uuid:=gen_random_uuid();
  existing public.orders%rowtype;
  prod public.products%rowtype;
  item record;
  fee numeric;
  gross numeric(14,2):=0;
  disc numeric(14,2):=0;
  email_normalized text:=lower(trim(coalesce(p_guest_email,'')));
  phone_normalized text:=regexp_replace(coalesce(p_shipping_phone,''),'[^0-9+]','','g');
  token_hash text;
begin
  if auth.uid() is not null then raise exception 'Use member checkout while signed in';end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty';end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines';end if;
  if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity<1 or quantity>99) then raise exception 'Invalid basket line';end if;
  if email_normalized!~'^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Enter a valid email address';end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_name,'')))>120 then raise exception 'Enter a valid delivery name';end if;
  if length(phone_normalized)<7 or length(phone_normalized)>20 then raise exception 'Enter a valid delivery phone';end if;
  if length(trim(coalesce(p_shipping_address,'')))<8 or length(trim(coalesce(p_shipping_address,'')))>500 then raise exception 'Enter a complete delivery address';end if;
  if length(trim(coalesce(p_shipping_city,'')))<2 or length(trim(coalesce(p_shipping_city,'')))>100 then raise exception 'Enter a valid city';end if;
  if length(coalesce(p_idempotency_key,''))<12 or length(coalesce(p_access_token,''))<32 then raise exception 'Invalid guest order request';end if;
  token_hash:=md5(p_access_token);
  perform pg_advisory_xact_lock(hashtextextended('guest-order:'||email_normalized||':'||p_idempotency_key,0));
  select * into existing from public.orders where idempotency_key='guest:'||email_normalized||':'||p_idempotency_key;
  if existing.id is not null then
    if existing.guest_access_token_hash<>token_hash then raise exception 'Guest order token mismatch';end if;
    return jsonb_build_object('order_id',existing.id,'order_code',existing.order_code,'status',existing.status);
  end if;
  if (select count(*) from public.orders where buyer_id is null and lower(guest_email)=email_normalized and regexp_replace(shipping_phone,'[^0-9+]','','g')=phone_normalized and created_at>now()-interval '1 hour' and status not in('cancelled','returned'))>=5 then
    raise exception 'Too many recent guest orders. Please try again later';
  end if;
  select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
  if fee is null then raise exception 'Delivery charges are awaiting company configuration';end if;
  perform set_config('mio.affiliate_code',coalesce(trim(p_affiliate_code),''),true);
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate,guest_email,guest_access_token_hash)
  values(oid,'GST-'||upper(substr(replace(oid::text,'-',''),1,10)),null,0,fee,fee,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),trim(p_shipping_address),trim(p_shipping_city),'guest:'||email_normalized||':'||p_idempotency_key,300,email_normalized,token_hash);
  for item in select product_id,sum(quantity)::integer quantity from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) group by product_id order by product_id loop
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status<>'approved' or prod.stock_quantity<item.quantity then raise exception 'A selected product is unavailable or out of stock';end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active';end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity) values(oid,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    gross:=gross+prod.price_pkr*item.quantity;
  end loop;
  if gross<=0 then raise exception 'Basket total must be positive';end if;
  select coalesce(sum(buyer_discount_pkr),0) into disc from public.order_items where order_id=oid;
  update public.orders set discount_pkr=disc,subtotal_pkr=gross-disc,total_pkr=gross-disc+fee where id=oid;
  perform set_config('mio.affiliate_code','',true);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(null,'GUEST_MARKETPLACE_ORDER_PLACED','order',oid,jsonb_build_object('order_code',(select order_code from public.orders where id=oid),'guest',true,'affiliate_attributed',exists(select 1 from public.orders where id=oid and selling_affiliate_id is not null)));
  return (select jsonb_build_object('order_id',id,'order_code',order_code,'status',status) from public.orders where id=oid);
end $$;

create or replace function public.guest_order_status(p_order_code text,p_access_token text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
  if length(coalesce(p_access_token,''))<32 then raise exception 'Guest order access denied';end if;
  select * into o from public.orders where upper(order_code)=upper(trim(p_order_code)) and buyer_id is null and guest_access_token_hash=md5(p_access_token);
  if o.id is null then raise exception 'Guest order access denied';end if;
  return jsonb_build_object(
    'id',o.id,'order_code',o.order_code,'created_at',o.created_at,'status',o.status,'payment_status',o.payment_status,'payment_method',o.payment_method,
    'subtotal_pkr',o.subtotal_pkr,'discount_pkr',o.discount_pkr,'delivery_fee_pkr',o.delivery_fee_pkr,'total_pkr',o.total_pkr,
    'shipping_name',o.shipping_name,'shipping_phone',o.shipping_phone,'shipping_address',o.shipping_address,'shipping_city',o.shipping_city,
    'affiliate_attributed',o.selling_affiliate_id is not null,'rewards_credited_at',o.rewards_credited_at,
    'items',coalesce((select jsonb_agg(jsonb_build_object('product_name_snapshot',i.product_name_snapshot,'unit_price_pkr',i.unit_price_pkr,'quantity',i.quantity,'line_total_pkr',i.line_total_pkr) order by i.created_at,i.id) from public.order_items i where i.order_id=o.id),'[]'::jsonb)
  );
end $$;

-- A guest without an affiliate has no member reward owner. Mark the reward route complete
-- without creating PPV, MIO, team bonuses or a synthetic member account.
create or replace function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;ppv numeric;total numeric;funding numeric;r record;outcome jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 select * into o from public.orders where id=new.id for update;
 if o.status in('cancelled','returned') and o.rewards_credited_at is null then update public.ecommerce_rewards set status='cancelled' where order_id=o.id and status='pending_delivery';return new;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if o.reward_owner_id is null then
  update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;
  perform private.sync_company_treasury();return new;
 end if;
 if o.reward_version=1 then o.reward_owner_id:=o.buyer_id;perform private.post_shopping_rewards(o.id);
 else
  select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards';
  if ppv*300>funding then raise exception 'Order rewards exceed verified funding';end if;
  if o.reward_mode='MIO' then
   for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop perform private.credit_ecommerce_reward(r.id);end loop;
   update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;
  else
   dp_base:=trunc(ppv*coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric,1),4);gp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric,.5),4);bp_base:=trunc(dp_base*coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric,.5),4);
   insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,dp,gp,bp,binary_reserve_mio) values(o.id,o.reward_owner_id,funding,ppv,dp_base,gp_base,bp_base,trunc(bp_base*coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric,.35),4)) on conflict do nothing;
   if found then outcome:=private.distribute_mlm_event(o.reward_owner_id,ppv,o.id,null,o.rules_snapshot);update public.shopping_reward_events set direct_generation_mio=(outcome->>'direct_generation')::numeric,single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;end if;
  end if;
 end if;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.reward_owner_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);perform private.sync_company_treasury();return new;
end$$;

revoke all on function public.place_guest_affiliate_order(jsonb,text,text,text,text,text,text,text,text),public.guest_order_status(text,text) from public,anon,authenticated;
grant execute on function public.place_guest_affiliate_order(jsonb,text,text,text,text,text,text,text,text),public.guest_order_status(text,text) to anon;
grant execute on function public.guest_order_status(text,text) to authenticated;
revoke all on function private.release_order_rewards() from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261013215000_tree_binary_team_counts.sql =====
-- Add permanent LEFT and RIGHT binary downline counts to graphical tree nodes.
create or replace function private.binary_team_counts(p_member uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
 with recursive downline(id,root_side,path) as (
  select b.member_id,b.side,array[p_member,b.member_id]
  from public.binary_placements b
  where b.parent_id=p_member
  union all
  select b.member_id,d.root_side,d.path||b.member_id
  from downline d
  join public.binary_placements b on b.parent_id=d.id
  where not b.member_id=any(d.path)
 )
 select jsonb_build_object(
  'left',count(*) filter(where root_side='LEFT'),
  'right',count(*) filter(where root_side='RIGHT')
 )
 from downline;
$$;

revoke all on function private.binary_team_counts(uuid) from public,anon,authenticated;

do $$
declare
 f text;
 old_fragment text;
 new_fragment text;
begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 -- TNBP is a lifetime total.  Match the fragment introduced by the
 -- preceding lifetime-total migration; carry-forward calculations are the
 -- only binary values scoped by completed distributions/reset boundaries.
 old_fragment:='''total_right_bp'',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type=''BP'' and side=''RIGHT''),0)';
 new_fragment:=old_fragment||
  ',''left_team_count'',coalesce((private.binary_team_counts(t.id)->>''left'')::integer,0)'||
  ',''right_team_count'',coalesce((private.binary_team_counts(t.id)->>''right'')::integer,0)';
 if position(old_fragment in f)=0 then
  raise exception 'Expected graphical tree total BP fragment was not found';
 end if;
 f:=replace(f,old_fragment,new_fragment);
 execute f;
end
$$;

notify pgrst,'reload schema';


-- ===== schema/20261014000100_allow_signup_sponsor_preview.sql =====
-- Registration happens before authentication, so anonymous visitors need read-only
-- access to the narrowly scoped sponsor-code lookup function.
grant execute on function public.lookup_side_referral(text) to anon, authenticated;
notify pgrst, 'reload schema';


-- ===== schema/20261014090000_progressive_generation_and_full_platinum.sql =====
-- Generation qualification is progressive and capped by the member's package:
-- 1 direct + 20 DP => 2 levels, ... 5 directs + 100 DP => 10 levels.
create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer
language sql stable security definer set search_path=''
as $$
 with plan as (
  select coalesce((p_cfg->'plans'->coalesce(private.current_package_code(p_member),'BASIC_1')->>'max_generations')::integer,0) package_levels
 ), d as (
  select * from private.direct_dp_summary(p_member)
 ), earned as (
  select case
   when active_directs>=5 and total_dp>=100 then 10
   when active_directs>=4 and total_dp>=80 then 8
   when active_directs>=3 and total_dp>=60 then 6
   when active_directs>=2 and total_dp>=40 then 4
   when active_directs>=1 and total_dp>=20 then 2
   else 0
  end levels
  from d
 )
 select least(plan.package_levels,earned.levels) from plan cross join earned;
$$;

-- Platinum is a fresh full-price activation even when a lower plan is active.
-- Other upgrades remain incremental.
create or replace function public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
 member uuid := (select auth.uid());
 p public.package_versions%rowtype;
 current_p public.package_versions%rowtype;
 current_code text;
 activation uuid;
 new_balance numeric(20,4);
 due_base numeric(14,2); due_fee numeric(14,2); due_payable numeric(14,2);
 due_ppv numeric(14,4); due_bv numeric(14,4); due_dp numeric(14,4);
 due_gp numeric(14,4); due_bp numeric(14,4); due_brp numeric(14,4);
begin
 if member is null then raise exception 'Authentication required';end if;
 if length(coalesce(p_idempotency_key,''))<12 then raise exception 'Invalid idempotency key';end if;
 if not exists(select 1 from public.member_profiles where user_id=member) then raise exception 'Member account required';end if;
 select * into p from public.package_versions where package_code=p_package_code and is_active
  and effective_from<=now() and (effective_to is null or effective_to>now()) order by version desc limit 1;
 if p.package_code is null then raise exception 'Package not available';end if;
 perform pg_advisory_xact_lock(hashtextextended('package-member:'||member::text,0));
 select id into activation from public.package_activations where member_id=member and idempotency_key=member::text||':'||p_idempotency_key;
 if activation is not null then return activation;end if;
 current_code:=private.current_package_code(member);
 if current_code is not null then
  select * into current_p from public.package_versions where package_code=current_code order by version desc limit 1;
  if p.payable_price<=coalesce(current_p.payable_price,0) then raise exception 'Choose a higher package tier';end if;
 end if;
 if p.package_code='PREMIUM' then
  due_base:=p.base_value;due_fee:=p.company_fee;due_payable:=p.payable_price;
  due_ppv:=p.ppv;due_bv:=p.bv;due_dp:=p.dp;due_gp:=p.gp;due_bp:=p.bp;due_brp:=p.brp;
 else
  due_base:=p.base_value-coalesce(current_p.base_value,0);
  due_fee:=p.company_fee-coalesce(current_p.company_fee,0);
  due_payable:=p.payable_price-coalesce(current_p.payable_price,0);
  due_ppv:=p.ppv-coalesce(current_p.ppv,0);due_bv:=p.bv-coalesce(current_p.bv,0);
  due_dp:=p.dp-coalesce(current_p.dp,0);due_gp:=p.gp-coalesce(current_p.gp,0);
  due_bp:=p.bp-coalesce(current_p.bp,0);due_brp:=p.brp-coalesce(current_p.brp,0);
 end if;
 if due_payable<=0 or due_base<=0 or due_ppv<=0 then raise exception 'Choose a higher package tier';end if;
 update public.mio_wallet_accounts set balance=balance-due_payable,updated_at=now()
  where member_id=member and balance>=due_payable returning balance into new_balance;
 if new_balance is null then raise exception 'Insufficient MIO Points';end if;
 activation:=gen_random_uuid();
 insert into public.package_activations(
  id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,
  base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,
  status,activated_at,approved_by,idempotency_key)
 values(activation,member,p.package_code,p.version,'MIO_POINTS',p_idempotency_key,'MIO',due_payable,1,
  due_base,due_fee,due_payable,due_ppv,due_bv,due_dp,due_gp,due_bp,due_brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
  'approved',now(),member,member::text||':'||p_idempotency_key);
 insert into public.mio_ledger(member_id,amount,action,activation_id,idempotency_key)
  values(member,-due_payable,'package_activation',activation,member::text||':'||p_idempotency_key||':mio');
 insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
  values(member,'PPV',due_ppv,activation,'credit',member::text||':'||p_idempotency_key||':ppv');
 perform private.credit_activation_bonuses(activation);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
  values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,
   jsonb_build_object('package_code',p.package_code,'upgrade_due_mio',due_payable,'ppv_credited',due_ppv,
    'previous_package',current_code,'full_price_platinum',p.package_code='PREMIUM'));
 return activation;
end;
$$;

revoke all on function private.generation_levels_by_dp(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.activate_package_with_mio(text,text) from public,anon;
grant execute on function public.activate_package_with_mio(text,text) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261014124000_member_generation_level_status.sql =====
create or replace function public.my_generation_level_status()
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
 member uuid:=auth.uid();
 cfg jsonb;
 code text;
 plan jsonb;
 active_count integer:=0;
 dp_total numeric:=0;
 allowed_count integer:=0;
 unlocked_count integer:=0;
begin
 if member is null then raise exception 'Authentication required';end if;
 if not private.registered_member(member) then raise exception 'Member account required';end if;
 cfg:=private.current_mlm_rules();
 code:=private.current_package_code(member);
 if code is not null then
  plan:=cfg->'plans'->code;
  allowed_count:=coalesce((plan->>'max_generations')::integer,0);
  unlocked_count:=private.generation_levels_by_dp(member,cfg);
 end if;
 select active_directs,total_dp into active_count,dp_total from private.direct_dp_summary(member);
 return jsonb_build_object('package_code',code,'package_name',coalesce(plan->>'display_name','Free account'),'allowed_levels',allowed_count,'unlocked_levels',unlocked_count,'active_directs',coalesce(active_count,0),'working_dp',coalesce(dp_total,0),'rules_version',cfg->>'version');
end;
$$;
revoke all on function public.my_generation_level_status() from public,anon;
grant execute on function public.my_generation_level_status() to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261014180000_financial_reset_boundary.sql =====
-- Shared financial reset boundary used by points, pool and dashboard reports.
-- No reset is applied until FINANCIAL_RESET is explicitly configured.
create or replace function private.financial_reset_at()
returns timestamptz
language sql
stable
security definer
set search_path=''
as $$
 select coalesce(
  (select (config_value->>'reset_at')::timestamptz
   from public.system_config
   where config_key='FINANCIAL_RESET' and effective_to is null
   order by version desc limit 1),
  '-infinity'::timestamptz
 );
$$;

revoke all on function private.financial_reset_at() from public,anon,authenticated;


-- ===== schema/20261014190000_realtime_binary_shares.sql =====
-- Binary shares accrue in real time from matched BP. Admin may distribute at any time.
-- Shares are earned in 0.1 increments; distribution consumes only the matched BP
-- represented by the paid shares. Lifetime BP remains in point_ledger.

alter table public.binary_member_results
  alter column completed_shares type numeric(18,4) using completed_shares::numeric;

alter table public.binary_cycles
  alter column total_completed_shares type numeric(18,4) using total_completed_shares::numeric;

create or replace function public.admin_binary_pool_dashboard()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cutoff timestamptz:=private.financial_reset_at(); last_end timestamptz;
 period_start timestamptz; period_end timestamptz:=clock_timestamp(); total_wallet numeric:=0;
 current_pool numeric:=0; last_distributed numeric:=0; total_shares numeric:=0;
 package_json jsonb:='[]'::jsonb; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 cfg:=private.current_mlm_rules();
 share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then share_points:=50; end if;
 select max(ends_at) into last_end from public.binary_cycles
  where status in('posted','unallocated') and created_at>cutoff;
 period_start:=coalesce(last_end,cutoff);

 select greatest(0,
   coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)
   +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)
   -coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated') and created_at>cutoff),0))
 into total_wallet;
 current_pool:=total_wallet;

 with active_package as (
  select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,
   coalesce((cfg->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
  from public.package_activations a
  join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
  where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=period_end
  order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
 ), volume as (
  select pl.member_id,
   coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,
   coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
  from public.point_ledger pl
  where pl.point_type='BP' and pl.created_at>cutoff and pl.created_at<=period_end
  group by pl.member_id
 ), consumed as (
  select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
  from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
  where c.status in('posted','unallocated') and c.created_at>cutoff group by r.member_id
 ), shares as (
  select ap.package_code,
   trunc(least(greatest(coalesce(v.l,0)-coalesce(c.l,0),0),greatest(coalesce(v.r,0)-coalesce(c.r,0),0))/share_points,1) completed
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 )
 select coalesce(sum(shares),0),
  coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb)
 into total_shares,package_json
 from (select package_code,sum(completed) shares from shares group by package_code having sum(completed)>0) p;

 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles
  where status='posted' and created_at>cutoff order by ends_at desc limit 1;
 return jsonb_build_object(
  'total_pool_wallet',total_wallet,'current_pool',current_pool,'this_week_pool',current_pool,
  'last_distributed',last_distributed,'total_shares',coalesce(total_shares,0),
  'shares_by_package',package_json,'share_points_each_side',share_points,
  'period_start',period_start,'period_end',period_end,
  'can_distribute',coalesce(total_shares,0)>0 and total_wallet>0,
  'default_share_value',case when coalesce(total_shares,0)>0 then trunc(total_wallet/total_shares,4) else 0 end,
  'next_cycle_code','REALTIME-'||to_char(period_end at time zone 'Asia/Karachi','YYYYMMDD-HH24MISS'));
end;
$$;

create or replace function public.admin_close_binary_cycle(
 p_cycle_code text,p_starts_at timestamptz,p_ends_at timestamptz,p_timezone text,p_manual_share_value numeric default null)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 admin_id uuid:=auth.uid(); cycle uuid:=gen_random_uuid(); cutoff timestamptz:=private.financial_reset_at();
 reserved_pool numeric:=0; pool numeric:=0; share_count numeric:=0; m record; gross numeric;
 member_pay numeric; remainder numeric; residual_recipient uuid; txn uuid; key text; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_manual_share_value is null or p_manual_share_value<0 then raise exception 'Enter a valid share price'; end if;
 if p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at or p_ends_at>clock_timestamp()+interval '5 seconds' then raise exception 'Invalid distribution period'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 cfg:=private.current_mlm_rules(); share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then raise exception 'Binary share points rule is invalid'; end if;
 if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Distribution reference already exists'; end if;
 select greatest(0,
   coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)
   +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)
   -coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated') and created_at>cutoff),0))
 into reserved_pool;
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
 values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,p_timezone,0,0,0,'open');

 for m in
  with active_package as (
   select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,
    coalesce((cfg->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) binary_entitlement
   from public.package_activations a join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
   where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=p_ends_at
   order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
  ), volume as (
   select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
   from public.point_ledger pl where pl.point_type='BP' and pl.created_at>cutoff and pl.created_at<=p_ends_at group by pl.member_id
  ), consumed as (
   select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
   from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
   where c.status in('posted','unallocated') and c.created_at>cutoff group by r.member_id
  )
  select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) l,greatest(coalesce(v.r,0)-coalesce(c.r,0),0) r
  from active_package ap left join volume v on v.member_id=ap.member_id left join consumed c on c.member_id=ap.member_id
 loop
  gross:=trunc(least(m.l,m.r)/share_points,1);
  if gross>0 then
   insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)
   values(cycle,m.member_id,m.package_code,m.package_version,m.l,m.r,gross,m.binary_entitlement,0,0,0,gross*share_points,gross*share_points,m.l-gross*share_points,m.r-gross*share_points,jsonb_build_object('qualification','active_package_and_realtime_fractional_share','share_points_each_side',share_points,'share_increment',0.1,'manual_share_price',p_manual_share_value));
  end if;
 end loop;
 select coalesce(sum(completed_shares),0) into share_count from public.binary_member_results where cycle_id=cycle;
 if share_count<=0 then raise exception 'No payable binary shares are available'; end if;
 pool:=trunc(p_manual_share_value*share_count,4);
 if pool>reserved_pool+.00000001 then raise exception 'Share price exceeds current binary pool wallet'; end if;
 update public.binary_cycles set pool_amount=pool,total_completed_shares=share_count,gross_share_value=p_manual_share_value,status='frozen' where id=cycle;
 update public.binary_member_results set gross_amount=trunc(p_manual_share_value*completed_shares,4),company_retention=trunc(p_manual_share_value*completed_shares,4) where cycle_id=cycle;
 select pool-coalesce(sum(gross_amount),0) into remainder from public.binary_member_results where cycle_id=cycle;
 for residual_recipient in select member_id from public.binary_member_results where cycle_id=cycle and completed_shares>0 order by member_id limit greatest(round(remainder*10000)::integer,0)
 loop update public.binary_member_results set gross_amount=gross_amount+0.0001,company_retention=company_retention+0.0001 where cycle_id=cycle and member_id=residual_recipient; end loop;
 for m in select * from public.binary_member_results where cycle_id=cycle order by member_id loop
  gross:=m.gross_amount; member_pay:=trunc(gross*m.entitlement,4);
  update public.binary_member_results set member_amount=member_pay,company_retention=gross-member_pay where cycle_id=cycle and member_id=m.member_id;
  if member_pay>0 then
   key:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
   values(m.member_id,'binary_pool_share',cycle,gross,m.entitlement,gross,member_pay,'MIO','realtime-binary-pool-v1',jsonb_build_object('completed_shares',m.completed_shares,'share_points_each_side',share_points,'share_price',p_manual_share_value,'consumed_left',m.consumed_left,'consumed_right',m.consumed_right,'lifetime_bp_preserved',true),'posted',key) returning id into txn;
   update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing'; end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)
   values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Real-time Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 update public.binary_cycles set status='posted',closed_at=clock_timestamp() where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
 values(admin_id,'BINARY_REALTIME_DISTRIBUTED','binary_cycle',cycle,jsonb_build_object('pool',pool,'shares',share_count,'share_points_each_side',share_points,'share_price',p_manual_share_value));
 return cycle;
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb; cycle uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 d:=public.admin_binary_pool_dashboard();
 if coalesce((d->>'can_distribute')::boolean,false) is not true then raise exception 'No funded binary shares are ready'; end if;
 cycle:=public.admin_close_binary_cycle(d->>'next_cycle_code',(d->>'period_start')::timestamptz,clock_timestamp(),'Asia/Karachi',p_share_value);
 return jsonb_build_object('cycle_id',cycle,'cycle_code',d->>'next_cycle_code','share_price',p_share_value,'distributed_shares',d->>'total_shares');
end;
$$;

create or replace function public.admin_distribute_binary_pool(p_share_price numeric,p_total_amount numeric)
returns jsonb language sql security definer set search_path='' as $$
 select public.admin_distribute_binary_pool(p_share_price)
$$;

notify pgrst,'reload schema';


-- ===== schema/20261015070000_fix_dynamic_binary_share_distribution.sql =====
-- Remove the obsolete fixed 50-BP settlement check. The active BP/share rule
-- is versioned in MLM_PLANS and is recorded in each result snapshot.
alter table public.binary_member_results
  drop constraint if exists binary_member_results_check1;

alter table public.binary_member_results
  add constraint binary_member_results_consumption_check
  check (
    consumed_left = consumed_right
    and consumed_left >= 0
    and consumed_left <= left_available
    and consumed_right <= right_available
    and carry_left = left_available - consumed_left
    and carry_right = right_available - consumed_right
  );

create or replace function public.admin_distribute_binary_pool(p_share_value numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare cutoff timestamptz:=private.financial_reset_at();pend timestamptz:=clock_timestamp();pstart timestamptz;cycle uuid:=gen_random_uuid();code text;wallet numeric:=0;shares numeric:=0;pool numeric:=0;m record;gross numeric;pay numeric;txn uuid;k text;
begin
 if auth.uid()is null or not private.has_role('admin')then raise exception 'Admin access required';end if;
 if p_share_value is null or p_share_value<=0 then raise exception 'Enter a share price greater than zero';end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement',0));
 select coalesce(max(ends_at),cutoff)into pstart from public.binary_cycles where status in('posted','unallocated')and created_at>cutoff;
 select greatest(0,coalesce((select sum(binary_reserve_mio)from public.package_activations where status='approved'and source<>'SHOPPING_PPV'and coalesce(activated_at,requested_at)>cutoff),0)+coalesce((select sum(binary_reserve_mio)from public.shopping_reward_events where created_at>cutoff),0)-coalesce((select sum(pool_amount)from public.binary_cycles where status in('posted','unallocated')and created_at>cutoff),0))into wallet;
 select coalesce(sum(completed_shares),0)into shares from private.binary_live_shares(pend);
 if shares<=0 then raise exception 'No payable binary shares are available';end if;
 pool:=trunc(p_share_value*shares,4);
 if pool>wallet+.00000001 then raise exception 'Share price exceeds current binary pool wallet';end if;
 code:='REALTIME-'||to_char(pend at time zone 'Asia/Karachi','YYYYMMDD-HH24MISS-MS');
 insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,total_completed_shares,gross_share_value,status)values(cycle,code,pstart,pend,'Asia/Karachi',0,0,pool,shares,p_share_value,'frozen');
 for m in select * from private.binary_live_shares(pend)where completed_shares>0 order by member_id loop
  gross:=trunc(p_share_value*m.completed_shares,4);pay:=gross;
  insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,qualification_snapshot)values(cycle,m.member_id,m.package_code,m.package_version,m.left_available,m.right_available,m.completed_shares,1,gross,pay,0,m.consumed_each,m.consumed_each,m.left_available-m.consumed_each,m.right_available-m.consumed_each,jsonb_build_object('qualification','realtime_fractional_share','share_increment',.1,'share_price',p_share_value,'package_entitlement_snapshot',m.binary_entitlement,'lifetime_bp_preserved',true));
  if pay>0 then
   k:='binary:'||cycle::text||':'||m.member_id::text;
   insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)values(m.member_id,'binary_pool_share',cycle,gross,1,gross,pay,'MIO','realtime-binary-pool-v2',jsonb_build_object('completed_shares',m.completed_shares,'share_price',p_share_value,'package_entitlement_snapshot',m.binary_entitlement,'consumed_each_side',m.consumed_each,'pool_before',wallet,'pool_after',wallet-pool),'posted',k)returning id into txn;
   update public.mio_wallet_accounts set balance=balance+pay,updated_at=now()where member_id=m.member_id;
   if not found then raise exception 'Member wallet missing';end if;
   insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)values(m.member_id,pay,'bonus_credit',txn,cycle,'Real-time Binary Pool Share','binary-mio:'||txn::text);
  end if;
 end loop;
 update public.binary_cycles set status='posted',closed_at=clock_timestamp()where id=cycle;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)values(auth.uid(),'BINARY_REALTIME_DISTRIBUTED','binary_cycle',cycle,jsonb_build_object('pool_before',wallet,'distributed_pool',pool,'pool_after',wallet-pool,'shares',shares,'share_price',p_share_value));
 return jsonb_build_object('cycle_id',cycle,'cycle_code',code,'share_price',p_share_value,'distributed_shares',shares,'distributed_amount',pool,'remaining_pool',wallet-pool);
end$$;

notify pgrst,'reload schema';


-- ===== schema/20261015190000_binary_pool_cycle_balances.sql =====
-- Binary pool may be distributed at any time. The current-cycle inflow resets
-- after every distribution, while lifetime and wallet totals remain visible.
create or replace function public.admin_binary_pool_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 admin_id uuid:=auth.uid(); cutoff timestamptz:=private.financial_reset_at();
 last_end timestamptz; period_start timestamptz; period_end timestamptz:=clock_timestamp();
 total_generated numeric:=0; total_distributed numeric:=0; pool_wallet numeric:=0;
 current_cycle_balance numeric:=0; last_distributed numeric:=0; total_shares numeric:=0;
 package_json jsonb:='[]'::jsonb; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 cfg:=private.current_mlm_rules();
 share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then share_points:=50; end if;

 select max(ends_at) into last_end from public.binary_cycles
 where status in('posted','unallocated') and created_at>cutoff;
 period_start:=coalesce(last_end,cutoff);

 select coalesce((select sum(binary_reserve_mio) from public.package_activations
   where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)
  +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)
 into total_generated;
 select coalesce(sum(pool_amount),0) into total_distributed from public.binary_cycles
 where status in('posted','unallocated') and created_at>cutoff;
 pool_wallet:=greatest(0,total_generated-total_distributed);

 select coalesce((select sum(binary_reserve_mio) from public.package_activations
   where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>period_start),0)
  +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>period_start),0)
 into current_cycle_balance;

 select coalesce(sum(completed_shares),0) into total_shares from private.binary_live_shares(period_end);
 select coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb)
 into package_json from (
  select package_code,sum(completed_shares) shares from private.binary_live_shares(period_end)
  group by package_code having sum(completed_shares)>0
 ) q;
 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles
 where status='posted' and created_at>cutoff order by ends_at desc limit 1;

 return jsonb_build_object(
  'total_pool_generated',total_generated,
  'total_distributed',total_distributed,
  'total_pool_wallet',pool_wallet,
  'current_cycle_balance',current_cycle_balance,
  'last_distributed',last_distributed,
  'total_shares',total_shares,
  'shares_by_package',package_json,
  'share_points_each_side',share_points,
  'period_start',period_start,
  'period_end',period_end,
  'can_distribute',total_shares>0 and pool_wallet>0,
  'default_share_value',0,
  'next_cycle_code','ONDEMAND-'||to_char(period_end at time zone 'Asia/Karachi','YYYYMMDD-HH24MISS')
 );
end$$;

revoke all on function public.admin_binary_pool_dashboard() from public,anon;
grant execute on function public.admin_binary_pool_dashboard() to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261015223000_generation_member_drilldown.sql =====
create or replace function public.my_generation_member_details(p_member_code text)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
 viewer_id uuid:=auth.uid();
 target_id uuid;
 cfg jsonb;
 target_code text;
 package_code text;
 package_name text;
 allowed_levels integer:=0;
 unlocked_levels integer:=0;
 v_active_directs integer:=0;
 v_working_dp numeric:=0;
 result jsonb;
begin
 if viewer_id is null or not private.registered_member(viewer_id) then
  raise exception 'Member account required';
 end if;

 target_code:='MIO-'||regexp_replace(upper(trim(coalesce(p_member_code,''))),'^MIO-','');
 select user_id into target_id from public.member_profiles where member_code=target_code;
 if target_id is null then raise exception 'Member not found'; end if;

 if not private.has_role('admin') and target_id<>viewer_id then
  if not exists(
   with recursive permitted(id,depth,path) as (
    select viewer_id,0,array[viewer_id]
    union all
    select m.user_id,p.depth+1,p.path||m.user_id
    from permitted p join public.member_profiles m on m.sponsor_id=p.id
    where p.depth<10 and not m.user_id=any(p.path)
   ) select 1 from permitted where id=target_id
  ) then raise exception 'Member is outside your permitted network'; end if;
 end if;

 cfg:=private.current_mlm_rules();
 package_code:=private.current_package_code(target_id);
 if package_code is not null then
  package_name:=coalesce(cfg->'plans'->package_code->>'display_name',package_code);
  allowed_levels:=coalesce((cfg->'plans'->package_code->>'max_generations')::integer,0);
  unlocked_levels:=private.generation_levels_by_dp(target_id,cfg);
 else
  package_name:='Free account';
 end if;
 select d.active_directs,d.total_dp into v_active_directs,v_working_dp from private.direct_dp_summary(target_id) d;

 with recursive descendants(id,parent_id,depth,path) as (
  select m.user_id,m.sponsor_id,1,array[target_id,m.user_id]
  from public.member_profiles m where m.sponsor_id=target_id
  union all
  select m.user_id,m.sponsor_id,d.depth+1,d.path||m.user_id
  from descendants d join public.member_profiles m on m.sponsor_id=d.id
  where d.depth<10 and not m.user_id=any(d.path)
 ), member_rows as (
  select d.depth,m.user_id,m.full_name,m.member_code,m.status,m.created_at,m.profile_photo_url,
   private.current_package_code(m.user_id) member_package
  from descendants d join public.member_profiles m on m.user_id=d.id
 ), generations as (
  select level,
   coalesce((select count(*) from member_rows r where r.depth=level),0)::integer member_count,
   coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.user_id,'full_name',r.full_name,'member_code',r.member_code,'status',r.status,
    'joined_at',r.created_at,'profile_photo_url',r.profile_photo_url,'package',r.member_package
   ) order by r.created_at,r.member_code) from member_rows r where r.depth=level),'[]'::jsonb) members
  from generate_series(1,10) level
 ), gp_total as (
  select coalesce(sum(a.gp),0)::numeric value
  from descendants d join public.package_activations a on a.member_id=d.id and a.status='approved'
  where coalesce(a.activated_at,a.requested_at)>private.financial_reset_at()
 )
 select jsonb_build_object(
  'package_code',package_code,'package_name',package_name,
  'allowed_generations',allowed_levels,'active_generations',unlocked_levels,
  'direct_count',(select count(*) from member_rows where depth=1),
  'active_direct_count',coalesce(v_active_directs,0),'direct_points',coalesce(v_working_dp,0),
  'tngp',(select value from gp_total),'total_generation_network',(select count(*) from member_rows),
  'directs',coalesce((select members from generations where level=1),'[]'::jsonb),
  'generations',(select jsonb_agg(jsonb_build_object(
   'level',level,'member_count',member_count,'unlocked',level<=unlocked_levels,
   'allowed',level<=allowed_levels,'members',members
  ) order by level) from generations)
 ) into result;
 return result;
end;
$$;

revoke all on function public.my_generation_member_details(text) from public,anon;
grant execute on function public.my_generation_member_details(text) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261016090000_generation_tree_side_dp_gp.sql =====
-- Show actual DP and GP volume under each permanent binary placement side.
create or replace function private.binary_side_dp_gp_totals(p_member uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
 with recursive downline(id,root_side,path) as (
  select b.member_id,b.side,array[p_member,b.member_id]
  from public.binary_placements b
  where b.parent_id=p_member
  union all
  select b.member_id,d.root_side,d.path||b.member_id
  from downline d
  join public.binary_placements b on b.parent_id=d.id
  where not b.member_id=any(d.path)
 ), totals as (
  select
   d.root_side,
   coalesce(sum(pl.amount) filter(where pl.point_type='DP'),0) as dp,
   coalesce(sum(pl.amount) filter(where pl.point_type='GP'),0) as gp
  from downline d
  left join public.point_ledger pl
   on pl.member_id=d.id
   and pl.created_at>private.financial_reset_at()
  group by d.root_side
 )
 select jsonb_build_object(
  'left_dp',coalesce((select dp from totals where root_side='LEFT'),0),
  'right_dp',coalesce((select dp from totals where root_side='RIGHT'),0),
  'left_gp',coalesce((select gp from totals where root_side='LEFT'),0),
  'right_gp',coalesce((select gp from totals where root_side='RIGHT'),0)
 );
$$;

revoke all on function private.binary_side_dp_gp_totals(uuid) from public,anon,authenticated;

do $$
declare
 f text;
 old_fragment text;
 new_fragment text;
begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 old_fragment:='''right_team_count'',coalesce((private.binary_team_counts(t.id)->>''right'')::integer,0)';
 new_fragment:=old_fragment||
  ',''left_dp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''left_dp'')::numeric,0)'||
  ',''right_dp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''right_dp'')::numeric,0)'||
  ',''left_gp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''left_gp'')::numeric,0)'||
  ',''right_gp'',coalesce((private.binary_side_dp_gp_totals(t.id)->>''right_gp'')::numeric,0)';
 if position(old_fragment in f)=0 then
  raise exception 'Expected graphical tree team-count fragment was not found';
 end if;
 f:=replace(f,old_fragment,new_fragment);
 execute f;
end
$$;

notify pgrst,'reload schema';


-- ===== schema/current-functions.sql =====
CREATE OR REPLACE FUNCTION private.current_package_code(p_member_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.package_code
  from public.package_activations a
  where a.member_id = p_member_id and a.status = 'approved'
  order by a.activated_at desc nulls last, a.requested_at desc
  limit 1;
$function$

CREATE OR REPLACE FUNCTION public.admin_review_product(p_product_id uuid, p_approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid());
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  update public.products set status=case when p_approve then 'approved'::public.product_status else 'rejected'::public.product_status end,
    updated_at=now() where id=p_product_id and status in ('draft','pending');
  if not found then raise exception 'Reviewable product not found'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,case when p_approve then 'PRODUCT_APPROVED' else 'PRODUCT_REJECTED' end,'product',p_product_id,
      jsonb_build_object('status',case when p_approve then 'approved' else 'rejected' end));
end;
$function$

CREATE OR REPLACE FUNCTION private.has_role(_role app_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = _role
  );
$function$

CREATE OR REPLACE FUNCTION private.ensure_mio_wallet()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.mio_wallet_accounts(member_id) values (new.user_id)
  on conflict (member_id) do nothing;
  return new;
end;
$function$

CREATE OR REPLACE FUNCTION public.mio_transfer(p_recipient_id uuid, p_amount numeric, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$

CREATE OR REPLACE FUNCTION public.admin_mint_own_mio(p_amount numeric, p_reason text, p_idempotency_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$

CREATE OR REPLACE FUNCTION public.admin_burn_own_mio(p_amount numeric, p_reason text, p_idempotency_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$

CREATE OR REPLACE FUNCTION public.admin_set_company_vendor(p_vendor_id uuid, p_company_owned boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid());
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  update public.vendors set is_company_owned=p_company_owned where id=p_vendor_id and status='active';
  if not found then raise exception 'Active vendor not found'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'COMPANY_VENDOR_CLASSIFIED','vendor',p_vendor_id,jsonb_build_object('is_company_owned',p_company_owned));
end;
$function$

CREATE OR REPLACE FUNCTION private.activate_next_ppv_package(p_member_id uuid, p_order_id uuid, p_cumulative_ppv numeric)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rank_code text[] := array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2'];
  current_code text := private.current_package_code(p_member_id);
  current_rank integer := array_position(rank_code,current_code);
  i integer;
  p public.package_versions%rowtype;
  aid uuid;
  count_activated integer := 0;
  id_key text;
begin
  -- Premium never auto-activates or auto-upgrades through PPV.
  if current_code='PREMIUM' then return 0; end if;
  if current_rank is null then current_rank := 0; end if;
  for i in current_rank+1..4 loop
    select * into p from public.package_versions where package_code=rank_code[i] and is_active
      and effective_from <= now() and (effective_to is null or effective_to > now()) order by version desc limit 1;
    if p.package_code is null or p_cumulative_ppv < p.ppv then exit; end if;
    id_key := 'ppv:' || p_order_id::text || ':' || rank_code[i];
    if exists(select 1 from public.package_activations where idempotency_key=id_key) then continue; end if;
    aid := gen_random_uuid();
    insert into public.package_activations(
      id,member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,
      direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
    values(aid,p_member_id,p.package_code,p.version,'SHOPPING_PPV',p_order_id::text,p.base_value,p.company_fee,p.payable_price,
      p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,
      'approved',now(),null,id_key);
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values(p_member_id,'PPV',p.ppv,aid,'credit',id_key || ':ppv');
    perform private.credit_activation_bonuses(aid);
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(p_member_id,'PACKAGE_AUTO_ACTIVATED_PPV','package_activation',aid,
        jsonb_build_object('order_id',p_order_id,'package_code',p.package_code,'ppv_balance',p_cumulative_ppv));
    count_activated := count_activated+1;
  end loop;
  return count_activated;
end;
$function$

CREATE OR REPLACE FUNCTION public.set_featured_products(p_product_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$

CREATE OR REPLACE FUNCTION public.admin_set_usd_to_pkr_rate(p_rate numeric, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid()); next_version integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_rate is null or p_rate < 1 or p_rate > 10000 then raise exception 'Invalid USD to PKR rate'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'A reason/source is required'; end if;
  select coalesce(max(version),0)+1 into next_version from public.system_config where config_key='CURRENCY';
  update public.system_config set effective_to=now() where config_key='CURRENCY' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
    values('CURRENCY',next_version,jsonb_build_object('marketplace_currency','PKR','package_plan_currency','USD',
      'usd_to_pkr_rate',p_rate,'package_checkout_enabled',true,'rate_source',trim(p_reason)),now(),admin_id);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'USD_PKR_RATE_SET','system_config',jsonb_build_object('version',next_version,'rate',p_rate,'source',trim(p_reason)));
  return next_version;
end;
$function$

CREATE OR REPLACE FUNCTION public.place_marketplace_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  buyer uuid := (select auth.uid());
  order_id uuid := gen_random_uuid();
  order_code text;
  rate numeric(14,6);
  item record;
  prod public.products%rowtype;
  item_subtotal numeric(14,2) := 0;
  existing_id uuid;
begin
  if buyer is null then raise exception 'Sign in before placing an order'; end if;
  if not exists(select 1 from public.member_profiles where user_id=buyer and status='active') then raise exception 'Active account required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty'; end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines'; end if;
  if length(coalesce(p_idempotency_key,''))<12 then raise exception 'Invalid order request key'; end if;
  select id into existing_id from public.orders where idempotency_key=p_idempotency_key;
  if existing_id is not null then return existing_id; end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_phone,'')))<5
    or length(trim(coalesce(p_shipping_address,'')))<5 or length(trim(coalesce(p_shipping_city,'')))<2 then
    raise exception 'Complete delivery details are required';
  end if;
  select (config_value->>'usd_to_pkr_rate')::numeric into rate from public.system_config
    where config_key='CURRENCY' and effective_to is null order by version desc limit 1;
  if rate is null then raise exception 'Marketplace is waiting for the admin to configure the USD/PKR PPV conversion rate'; end if;

  order_code := 'MIO-' || upper(substr(replace(order_id::text,'-',''),1,10));
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,
    shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate)
  values(order_id,order_code,buyer,0,0,0,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),
    trim(p_shipping_address),trim(p_shipping_city),p_idempotency_key,rate);

  for item in select product_id,quantity from jsonb_to_recordset(p_items) as x(product_id uuid,quantity integer) loop
    if item.quantity is null or item.quantity<1 or item.quantity>99 then raise exception 'Invalid item quantity'; end if;
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status <> 'approved' or prod.stock_quantity < item.quantity then
      raise exception 'A selected product is unavailable or out of stock';
    end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active'; end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity)
      values(order_id,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    item_subtotal := item_subtotal+(prod.price_pkr*item.quantity);
  end loop;
  if item_subtotal<=0 then raise exception 'Basket total must be positive'; end if;
  update public.orders set subtotal_pkr=item_subtotal,total_pkr=item_subtotal where id=order_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(buyer,'MARKETPLACE_ORDER_PLACED','order',order_id,
      jsonb_build_object('order_code',order_code,'subtotal_pkr',item_subtotal,'usd_to_pkr_rate',rate,'ppv_status','pending payment confirmation'));
  return order_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.admin_review_vendor_application(p_application_id uuid, p_approve boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_id uuid := (select auth.uid()); app public.vendor_applications%rowtype; vendor uuid;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select * into app from public.vendor_applications where id=p_application_id for update;
  if app.id is null or app.status <> 'pending' then raise exception 'Pending application not found'; end if;
  update public.vendor_applications set status=case when p_approve then 'active'::public.vendor_status else 'rejected'::public.vendor_status end,
    reviewed_by=admin_id,reviewed_at=now() where id=app.id;
  if p_approve then
    insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,reviewed_by,reviewed_at)
      values(app.applicant_user_id,app.business_name,app.contact_email,app.contact_phone,app.description,'active',admin_id,now())
      on conflict(owner_user_id) do update set business_name=excluded.business_name,contact_email=excluded.contact_email,
        contact_phone=excluded.contact_phone,description=excluded.description,status='active',reviewed_by=admin_id,reviewed_at=now()
      returning id into vendor;
  else
    select id into vendor from public.vendors where owner_user_id=app.applicant_user_id;
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,case when p_approve then 'VENDOR_APPROVED' else 'VENDOR_REJECTED' end,'vendor_application',app.id,
      jsonb_build_object('applicant_id',app.applicant_user_id,'vendor_id',vendor));
  return vendor;
end;
$function$

CREATE OR REPLACE FUNCTION public.admin_confirm_order_payment(p_order_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  admin_id uuid := (select auth.uid());
  order_row public.orders%rowtype;
  ppv_value numeric(18,4);
  current_ppv numeric(18,4);
  activated integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select * into order_row from public.orders where id=p_order_id for update;
  if order_row.id is null then raise exception 'Order not found'; end if;
  if order_row.payment_status='confirmed' then return order_row.ppv_generated; end if;
  if order_row.payment_status<>'unconfirmed' or order_row.status in ('cancelled','returned') then
    raise exception 'Order is not eligible for payment confirmation';
  end if;
  ppv_value := round(order_row.subtotal_pkr/order_row.usd_to_pkr_rate,4);
  update public.orders set payment_status='confirmed',ppv_generated=ppv_value,updated_at=now() where id=order_row.id;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
    values(order_row.buyer_id,'PPV',ppv_value,order_row.id,'credit','order:' || order_row.id::text || ':ppv')
    on conflict(idempotency_key) do nothing;
  select coalesce(sum(amount),0) into current_ppv from public.point_ledger
    where member_id=order_row.buyer_id and point_type='PPV';
  activated := private.activate_next_ppv_package(order_row.buyer_id,order_row.id,current_ppv);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ORDER_PAYMENT_CONFIRMED','order',order_row.id,
      jsonb_build_object('buyer_id',order_row.buyer_id,'ppv_generated',ppv_value,'cumulative_ppv',current_ppv,'auto_activations',activated));
  return ppv_value;
end;
$function$

CREATE OR REPLACE FUNCTION public.mio_transfer_to_member_code(p_recipient_code text, p_amount numeric, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare recipient uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  select user_id into recipient from public.member_profiles
    where upper(member_code)=upper(trim(p_recipient_code)) or upper(referral_code)=upper(trim(p_recipient_code))
    limit 1;
  if recipient is null then raise exception 'Member code not found'; end if;
  return public.mio_transfer(recipient,p_amount,p_idempotency_key);
end;
$function$

CREATE OR REPLACE FUNCTION private.credit_activation_bonuses(p_activation_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  act public.package_activations%rowtype;
  direct_sponsor uuid;
  beneficiary uuid;
  receiver_activation public.package_activations%rowtype;
  recipient record;
  gen_depth integer;
  gen_limit integer;
  gen1_rate numeric(10,8);
  gen2_rate numeric(10,8) := 0.05;
  stack_gen1 boolean := false;
  applied integer := 0;
  txn_id uuid;
  payout numeric(18,4);
  rate numeric(10,8);
  key text;
begin
  select * into act from public.package_activations where id=p_activation_id;
  if act.id is null or act.status<>'approved' then return 0; end if;
  select (config_value->>'direct_and_gen1_stack')::boolean,
         coalesce((config_value->>'gen2_plus_rate')::numeric,0.05)
    into stack_gen1,gen2_rate
    from public.system_config where config_key='GENERATION' and effective_to is null
    order by version desc limit 1;
  stack_gen1 := coalesce(stack_gen1,false);
  gen2_rate := coalesce(gen2_rate,0.05);
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=act.member_id;

  if direct_sponsor is not null and exists(select 1 from public.member_profiles where user_id=direct_sponsor and status='active')
     and private.current_package_code(direct_sponsor) is not null then
    payout := round(act.bv*act.direct_rate,4);
    if payout>0 then
      key := 'direct:' || act.id::text;
      insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,qualifying_base,rate,gross_amount,
        payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
      values(direct_sponsor,'direct',act.id,act.bv,act.direct_rate,payout,payout,'MIO','phase1-direct-v1',
        jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'rate',act.direct_rate,'calculation','BV x direct rate'),
        'posted',key) on conflict(idempotency_key) do nothing returning id into txn_id;
      if txn_id is not null then
        update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=direct_sponsor;
        insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
          values(direct_sponsor,payout,'bonus_credit',act.id,txn_id,'Direct bonus','bonus:'||txn_id::text);
        applied := applied+1;
      end if;
    end if;
  end if;

  -- Loop over a bounded sponsor chain. Depth is capped by the configured maximum.
  for recipient in
    with recursive uplines(user_id,sponsor_id,depth,path) as (
      select m.user_id,m.sponsor_id,1,array[m.user_id] from public.member_profiles m where m.user_id=act.member_id
      union all
      select parent.user_id,parent.sponsor_id,u.depth+1,u.path||parent.user_id
        from uplines u join public.member_profiles parent on parent.user_id=u.sponsor_id
        where u.sponsor_id is not null and u.depth<10 and not parent.user_id=any(u.path)
    )
    select u.sponsor_id as member_id,u.depth as generation
      from uplines u where u.sponsor_id is not null order by u.depth
  loop
    beneficiary := recipient.member_id;
    gen_depth := recipient.generation;
    if not exists(select 1 from public.member_profiles where user_id=beneficiary and status='active') then continue; end if;
    select a into receiver_activation
      from public.package_activations a join public.package_versions pv
        on pv.package_code=a.package_code and pv.version=a.package_version
      where a.member_id=beneficiary and a.status='approved'
      order by a.activated_at desc nulls last,a.requested_at desc limit 1;
    select pv.max_generations,pv.generation1_rate into gen_limit,gen1_rate
      from public.package_versions pv where pv.package_code=receiver_activation.package_code
        and pv.version=receiver_activation.package_version;
    if receiver_activation.id is null or gen_depth>gen_limit then continue; end if;
    if gen_depth=1 and not stack_gen1 then continue; end if;
    rate := case when gen_depth=1 then gen1_rate else gen2_rate end;
    payout := round(act.bv*rate,4);
    if payout<=0 then continue; end if;
    key := 'generation:'||act.id::text||':'||beneficiary::text||':'||gen_depth::text;
    insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,
      gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
    values(beneficiary,'generation',act.id,gen_depth,act.bv,rate,payout,payout,'MIO','phase1-generation-v1',
      jsonb_build_object('source_package',act.package_code,'source_bv',act.bv,'beneficiary_package',receiver_activation.package_code,
        'generation',gen_depth,'rate',rate,'direct_gen1_stack',stack_gen1), 'posted',key)
    on conflict(idempotency_key) do nothing returning id into txn_id;
    if txn_id is not null then
      update public.mio_wallet_accounts set balance=balance+payout,updated_at=now() where member_id=beneficiary;
      insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
        values(beneficiary,payout,'bonus_credit',act.id,txn_id,'Generation bonus','bonus:'||txn_id::text);
      applied := applied+1;
    end if;
  end loop;
  return applied;
end;
$function$

CREATE OR REPLACE FUNCTION public.activate_package_with_mio(p_package_code text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.credit_activation_bonuses(activation);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(member,'PACKAGE_ACTIVATED_MIO','package_activation',activation,jsonb_build_object('package_code',p.package_code,'payable_mio',p.payable_price,'ppv_credited',p.ppv));
  return activation;
end;
$function$

CREATE OR REPLACE FUNCTION private.credit_binary_volume(p_activation_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  act public.package_activations%rowtype;
  current_member uuid;
  parent_member uuid;
  member_side text;
  depth integer := 0;
  credited integer := 0;
begin
  select * into act from public.package_activations where id=p_activation_id and status='approved';
  if act.id is null or act.bp<=0 then return 0; end if;
  current_member := act.member_id;
  loop
    select parent_id,side into parent_member,member_side from public.binary_placements where member_id=current_member;
    exit when parent_member is null;
    insert into public.point_ledger(member_id,point_type,amount,side,source_activation_id,entry_kind,idempotency_key)
      values(parent_member,'BP',act.bp,member_side,act.id,'credit',
        'bp:'||act.id::text||':'||parent_member::text)
      on conflict(idempotency_key) do nothing;
    if found then credited := credited+1; end if;
    current_member := parent_member;
    depth := depth+1;
    if depth>=100 then raise exception 'Binary placement depth limit reached'; end if;
  end loop;
  return credited;
end;
$function$

CREATE OR REPLACE FUNCTION private.create_member_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$

CREATE OR REPLACE FUNCTION public.admin_place_binary_member(p_member_code text, p_parent_code text, p_side text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  admin_id uuid := (select auth.uid());
  member uuid;
  parent uuid;
  activation_id uuid;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select user_id into member from public.member_profiles
    where upper(member_code)=upper(trim(p_member_code)) or upper(referral_code)=upper(trim(p_member_code)) limit 1;
  if member is null then raise exception 'Member code not found'; end if;
  if exists(select 1 from public.binary_placements where member_id=member) then raise exception 'Member already has a binary placement'; end if;
  if nullif(trim(coalesce(p_parent_code,'')),'') is null then
    if p_side is not null and trim(p_side)<>'' then raise exception 'Root placement has no side'; end if;
    if exists(select 1 from public.binary_placements where parent_id is null) then raise exception 'A binary root already exists'; end if;
    insert into public.binary_placements(member_id,parent_id,side,placed_by) values(member,null,null,admin_id);
  else
    select user_id into parent from public.member_profiles
      where upper(member_code)=upper(trim(p_parent_code)) or upper(referral_code)=upper(trim(p_parent_code)) limit 1;
    if parent is null then raise exception 'Parent code not found'; end if;
    if parent=member then raise exception 'A member cannot be placed under themselves'; end if;
    if not exists(select 1 from public.binary_placements where member_id=parent) then raise exception 'Place the parent before placing a child'; end if;
    if upper(trim(coalesce(p_side,''))) not in ('LEFT','RIGHT') then raise exception 'Choose LEFT or RIGHT'; end if;
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
      values(member,parent,upper(trim(p_side)),admin_id);
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'BINARY_MEMBER_PLACED','binary_placement',member,
      jsonb_build_object('parent_id',parent,'side',upper(nullif(trim(p_side),''))));
  -- If package activation preceded placement, now backfill this member's BP.
  for activation_id in select id from public.package_activations where member_id=member and status='approved' loop
    perform private.credit_binary_volume(activation_id);
  end loop;
  return member;
end;
$function$

CREATE OR REPLACE FUNCTION public.admin_close_binary_cycle(p_cycle_code text, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_timezone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  admin_id uuid := (select auth.uid());
  cycle uuid := gen_random_uuid();
  eligible numeric(18,4);
  pool numeric(18,8);
  share_count bigint;
  m record;
  previous_left numeric(18,4);
  previous_right numeric(18,4);
  new_left numeric(18,4);
  new_right numeric(18,4);
  shares bigint;
  gross numeric(18,8);
  member_pay numeric(18,8);
  retention numeric(18,8);
  txn uuid;
  key text;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if length(trim(coalesce(p_cycle_code,'')))<3 or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at then
    raise exception 'A cycle code and valid start/end are required';
  end if;
  if exists(select 1 from public.binary_cycles c where c.status not in ('reversed')
    and c.starts_at<p_ends_at and c.ends_at>p_starts_at) then raise exception 'Binary cycle overlaps an existing cycle'; end if;
  if exists(select 1 from public.binary_cycles where cycle_code=trim(p_cycle_code)) then raise exception 'Cycle code already exists'; end if;

  select coalesce(sum(base_value),0) into eligible from public.package_activations
    where status='approved' and activated_at>=p_starts_at and activated_at<p_ends_at;
  pool := round(eligible*0.35,8);
  insert into public.binary_cycles(id,cycle_code,starts_at,ends_at,cycle_timezone,eligible_base,pool_rate,pool_amount,status)
    values(cycle,trim(p_cycle_code),p_starts_at,p_ends_at,trim(coalesce(p_timezone,'Asia/Karachi')),eligible,0.35,pool,'open');

  -- First pass counts full 50/50 shares after the latest earlier carry.
  with active_package as (
    select distinct on (a.member_id) a.member_id,a.package_code,a.package_version,pv.binary_entitlement
      from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version
      join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
      where a.status='approved' and a.activated_at<p_ends_at
      order by a.member_id,a.activated_at desc nulls last,a.requested_at desc
  ), prior as (
    select ap.member_id,
      coalesce((select r.carry_left from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
        where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) left_carry,
      coalesce((select r.carry_right from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
        where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) right_carry
    from active_package ap
  ), volume as (
    select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) left_new,
      coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) right_new
    from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
    where pl.point_type='BP' and a.status='approved' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at
    group by pl.member_id
  )
  select coalesce(sum(floor(least(pr.left_carry+coalesce(v.left_new,0),pr.right_carry+coalesce(v.right_new,0))/50)::bigint),0)
    into share_count from prior pr left join volume v on v.member_id=pr.member_id;

  if share_count=0 then
    update public.binary_cycles set total_completed_shares=0,status='unallocated',closed_at=now() where id=cycle;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
      values(admin_id,'BINARY_CYCLE_UNALLOCATED','binary_cycle',cycle,jsonb_build_object('eligible_base',eligible,'pool',pool,'shares',0));
    return cycle;
  end if;
  update public.binary_cycles set total_completed_shares=share_count,gross_share_value=pool/share_count,status='frozen' where id=cycle;

  for m in
    with active_package as (
      select distinct on (a.member_id) a.member_id,a.package_code,a.package_version,pv.binary_entitlement
        from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version
        join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
        where a.status='approved' and a.activated_at<p_ends_at
        order by a.member_id,a.activated_at desc nulls last,a.requested_at desc
    ), prior as (
      select ap.*,
        coalesce((select r.carry_left from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
          where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) left_carry,
        coalesce((select r.carry_right from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id
          where r.member_id=ap.member_id and c.status in ('posted','unallocated') and c.ends_at<=p_starts_at order by c.ends_at desc limit 1),0) right_carry
      from active_package ap
    ), volume as (
      select pl.member_id,coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) left_new,
        coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) right_new
      from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id
      where pl.point_type='BP' and a.status='approved' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at
      group by pl.member_id
    ), balances as (
      select pr.member_id,pr.package_code,pr.package_version,pr.binary_entitlement,
        pr.left_carry+coalesce(v.left_new,0) left_available,pr.right_carry+coalesce(v.right_new,0) right_available
      from prior pr left join volume v on v.member_id=pr.member_id
    )
    select *,floor(least(left_available,right_available)/50)::bigint completed from balances
  loop
    shares := m.completed;
    gross := round((pool/share_count)*shares,8);
    member_pay := round(gross*m.binary_entitlement,4);
    retention := gross-member_pay;
    insert into public.binary_member_results(cycle_id,member_id,package_code,package_version,left_available,right_available,
      completed_shares,entitlement,gross_amount,member_amount,company_retention,consumed_left,consumed_right,carry_left,carry_right,
      qualification_snapshot)
    values(cycle,m.member_id,m.package_code,m.package_version,m.left_available,m.right_available,shares,m.binary_entitlement,
      gross,member_pay,retention,shares*50,shares*50,m.left_available-(shares*50),m.right_available-(shares*50),
      jsonb_build_object('qualification','active_package_and_full_share','pool_rate',0.35,'share_points_each_side',50));
    if member_pay>0 then
      key := 'binary:'||cycle::text||':'||m.member_id::text;
      insert into public.bonus_transactions(beneficiary_id,method,cycle_id,qualifying_base,rate,gross_amount,payable_amount,
        currency,formula_version,calculation_trace,status,idempotency_key)
      values(m.member_id,'binary_pool_share',cycle,gross,m.binary_entitlement,gross,member_pay,'MIO','phase1-binary-pool-v1',
        jsonb_build_object('completed_shares',shares,'entitlement',m.binary_entitlement,'gross_share_value',pool/share_count,
          'member_amount',member_pay,'company_retention',retention), 'posted',key)
      on conflict(idempotency_key) do nothing returning id into txn;
      if txn is not null then
        update public.mio_wallet_accounts set balance=balance+member_pay,updated_at=now() where member_id=m.member_id;
        insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,cycle_id,reason,idempotency_key)
          values(m.member_id,member_pay,'bonus_credit',txn,cycle,'Binary Pool Share','binary-mio:'||txn::text);
      end if;
    end if;
  end loop;
  update public.binary_cycles set status='posted',closed_at=now() where id=cycle;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'BINARY_CYCLE_POSTED','binary_cycle',cycle,
      jsonb_build_object('eligible_base',eligible,'pool_rate',0.35,'pool',pool,'completed_shares',share_count,'gross_share_value',pool/share_count));
  return cycle;
end;
$function$

CREATE OR REPLACE FUNCTION private.on_package_activation_binary_volume()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status='approved' then perform private.credit_binary_volume(new.id); end if;
  return new;
end;
$function$

CREATE OR REPLACE FUNCTION private.assign_activation_points()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status='approved' then
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values
        (new.member_id,'BV',new.bv,new.id,'credit','activation:'||new.id::text||':BV'),
        (new.member_id,'DP',new.dp,new.id,'credit','activation:'||new.id::text||':DP'),
        (new.member_id,'GP',new.gp,new.id,'credit','activation:'||new.id::text||':GP'),
        (new.member_id,'BRP',new.brp,new.id,'credit','activation:'||new.id::text||':BRP')
      on conflict do nothing;
    perform private.credit_activation_bonuses(new.id);
  end if;
  return new;
end;
$function$

CREATE OR REPLACE FUNCTION public.my_direct_referrals()
 RETURNS TABLE(member_code text, full_name text, created_at timestamp with time zone, status account_status)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select mp.member_code,mp.full_name,mp.created_at,mp.status
  from public.member_profiles mp
  where (select auth.uid()) is not null and mp.sponsor_id=(select auth.uid())
  order by mp.created_at desc;
$function$



-- ===== supabase/migrations/20261016023905_activation_offer_member_dashboard.sql =====
-- First activation starts one 15-day offer. Upgrades do not restart it.
-- Only future direct package-activation events use the promotion; shopping
-- and historical posted transactions retain their existing calculations.
create or replace function private.activation_offer_window(p_member uuid,p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
 with first_plan as (
  select min(coalesce(activated_at,requested_at)) starts_at
  from public.package_activations where member_id=p_member and status='approved'
 ), current_plan as (
  select private.package_eligible(p_member) eligible,
    coalesce((private.current_mlm_rules()->'plans'->private.current_package_code(p_member)->>'direct_rate')::numeric,0) normal_rate
 ) select jsonb_build_object('starts_at',starts_at,'ends_at',starts_at+interval '15 days',
  'eligible',coalesce(eligible and p_at>=starts_at and p_at<starts_at+interval '15 days',false),
  'normal_rate',normal_rate,'offer_rate',.40)
 from first_plan cross join current_plan;
$$;

create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor
  where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,
   private.package_eligible(u.id) eligible,private.generation_levels_by_dp(u.id,cfg) open_levels
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*case
    when eligible and coalesce((cfg->>'activation_offer_event')::boolean,false)
     and coalesce((private.activation_offer_window(id,coalesce((cfg->>'activation_offer_event_at')::timestamptz,now()))->>'eligible')::boolean,false)
    then .40 else coalesce((plan->>'direct_rate')::numeric,0) end
   else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=open_levels);
$$;

-- Keep all existing distribution/rounding/idempotency paths intact.
alter function private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb) rename to distribute_mlm_event_before_activation_offer;
create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare act public.package_activations%rowtype; sponsor uuid; offer jsonb; allocated numeric; available numeric; outcome jsonb;
begin
 cfg:=cfg-'activation_offer_event'-'activation_offer_event_at';
 if aid is not null and oid is null then
  select * into act from public.package_activations where id=aid;
  select sponsor_id into sponsor from public.member_profiles where user_id=member;
  offer:=private.activation_offer_window(sponsor,coalesce(act.activated_at,now()));
  if act.status='approved' and act.source<>'SHOPPING_PPV' and coalesce((offer->>'eligible')::boolean,false) then
   -- Preserve generation/binary budgets. Any promotional shortfall comes
   -- from this activation's admin fee and is removed from company fee income.
   available:=least(act.bv,act.base_value,act.payable_price-act.company_fee)+act.company_fee;
   allocated:=act.dp*.40
     +act.gp*(coalesce((cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((cfg->>'generation_manager_rate')::numeric,.05)+coalesce((cfg->>'generation_global_rate')::numeric,.20))
     +act.bp*(coalesce((cfg->>'binary_pool_rate')::numeric,.35)+coalesce((cfg->>'single_line_cap')::numeric,.10)+coalesce((cfg->>'binary_manager_rate')::numeric,.05)+coalesce((cfg->>'binary_global_rate')::numeric,.20));
   if allocated>available+.0001 then raise exception 'Activation offer exceeds funded package amount. Review plan budgets.';end if;
   cfg:=cfg||jsonb_build_object('activation_offer_event',true,'activation_offer_event_at',coalesce(act.activated_at,now()),'activation_offer_rate',.40);
  end if;
 end if;
 outcome:=private.distribute_mlm_event_before_activation_offer(member,b,oid,aid,cfg);
 return outcome;
end;
$$;

alter function private.company_treasury_sources_before_ecommerce() rename to company_treasury_sources_before_activation_offer;
create or replace function private.company_treasury_sources_before_ecommerce()
returns table(source_type text,source_id uuid,category text,currency text,amount numeric)
language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.currency,
  case when s.category='package_company_fee' then greatest(0,s.amount-coalesce((
   select greatest(0,
    a.gp*(coalesce((a.rules_snapshot->>'generation_bonus_rate')::numeric,.45)+coalesce((a.rules_snapshot->>'generation_manager_rate')::numeric,.05)+coalesce((a.rules_snapshot->>'generation_global_rate')::numeric,.20))
    +a.bp*(coalesce((a.rules_snapshot->>'binary_pool_rate')::numeric,.35)+coalesce((a.rules_snapshot->>'single_line_cap')::numeric,.10)+coalesce((a.rules_snapshot->>'binary_manager_rate')::numeric,.05)+coalesce((a.rules_snapshot->>'binary_global_rate')::numeric,.20))
    +coalesce((select sum(bt.payable_amount) from public.bonus_transactions bt where bt.source_activation_id=a.id and bt.method='direct' and bt.status in('pending','posted')),0)
    -least(a.bv,a.base_value,a.payable_price-a.company_fee))
   from public.package_activations a where a.id=s.source_id
    and exists(select 1 from public.bonus_transactions bt where bt.source_activation_id=a.id and bt.method='direct' and bt.calculation_trace->'plan_rules'->>'activation_offer_event'='true')
  ),0)) else s.amount end
 from private.company_treasury_sources_before_activation_offer() s;
$$;

create or replace function public.my_member_dashboard()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare member uuid:=auth.uid();p public.member_profiles%rowtype;g jsonb;v_binary jsonb;code text;cfg jsonb;shares numeric:=0;personal_gp numeric:=0;personal_bp numeric:=0;
begin
 if member is null or not private.registered_member(member) then raise exception 'Member account required';end if;
 select * into p from public.member_profiles where user_id=member;
 code:=private.current_package_code(member);cfg:=private.current_mlm_rules();
 g:=public.my_generation_member_details(p.member_code);
 select node into v_binary from jsonb_array_elements(public.my_network('binary',null,1)->'nodes') node where node->>'id'=member::text limit 1;
 select coalesce(sum(completed_shares),0) into shares from private.binary_live_shares(now()) where member_id=member;
 select coalesce(sum(amount) filter(where point_type='GP'),0),coalesce(sum(amount) filter(where point_type='BP'),0)
  into personal_gp,personal_bp from public.point_ledger where member_id=member and created_at>private.financial_reset_at();
 return jsonb_build_object('full_name',p.full_name,'member_code',p.member_code,'profile_photo_url',p.profile_photo_url,
  'enrolled_at',p.created_at,'package_code',code,'package_name',coalesce(cfg->'plans'->code->>'display_name','Free account'),
  'package_active',private.package_eligible(member),'generation',g,'binary',coalesce(v_binary,'{}'::jsonb),
  'personal_gp',personal_gp,'personal_bp',personal_bp,'pending_shares',shares,
  'share_points_each_side',coalesce((cfg->>'binary_share_points_each_side')::numeric,50),
  'activation_offer',private.activation_offer_window(member),'server_now',now());
end;
$$;

revoke all on function private.activation_offer_window(uuid,timestamptz),private.mlm_point_candidates(uuid,numeric,numeric,jsonb),
 private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb),private.distribute_mlm_event_before_activation_offer(uuid,numeric,uuid,uuid,jsonb),
 private.company_treasury_sources_before_ecommerce(),private.company_treasury_sources_before_activation_offer() from public,anon,authenticated;
revoke all on function public.my_member_dashboard() from public,anon;
grant execute on function public.my_member_dashboard() to authenticated;
notify pgrst,'reload schema';


-- ===== supabase/migrations/20261016145000_split_activation_welcome_bonus.sql =====
-- Keep the 15-day direct offer at 40%, but post it as two auditable rows:
-- the sponsor's normal package rate and the promotional welcome difference.
create or replace function private.mlm_point_candidates(member uuid,dp_base numeric,gp_base numeric,cfg jsonb)
returns table(beneficiary uuid,method public.bonus_method,depth integer,qualifying_base numeric,nominal numeric)
language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor
  where u.depth<10 and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,
   private.package_eligible(u.id) eligible,private.generation_levels_by_dp(u.id,cfg) open_levels
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*coalesce((plan->>'direct_rate')::numeric,0)
   else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and depth<=open_levels);
$$;

create or replace function private.guard_bonus_funding()
returns trigger language plpgsql security definer set search_path='' as $$
declare spent numeric;ceiling numeric;cfg jsonb;trace_cfg jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then
   select s.dp,s.gp,s.bp,o.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else
   select a.dp,a.gp,a.bp,a.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;
  end if;
  trace_cfg:=coalesce(new.calculation_trace->'plan_rules','{}'::jsonb);
  if new.method='direct' then
   ceiling:=trunc(dp_base*coalesce((trace_cfg->>'activation_offer_rate')::numeric,new.rate),4);
  elsif new.method='generation' then ceiling:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);
  else ceiling:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);end if;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions
   where status in('posted','pending')
    and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id))
    and method=new.method;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling+.0001 then raise exception 'Bonus would exceed its funded source budget';end if;
 return new;
end$$;

create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare act public.package_activations%rowtype;sponsor uuid;offer jsonb;allocated numeric;available numeric;outcome jsonb;
 normal_rate numeric:=0;welcome_rate numeric:=0;welcome_amount numeric:=0;tx uuid;state text;event_at timestamptz;
begin
 cfg:=cfg-'activation_offer_event'-'activation_offer_event_at'-'activation_offer_rate'-'activation_offer_normal_rate'-'activation_offer_welcome_rate';
 if aid is not null and oid is null then
  select * into act from public.package_activations where id=aid;
  select sponsor_id into sponsor from public.member_profiles where user_id=member;
  event_at:=coalesce(act.activated_at,now());
  offer:=private.activation_offer_window(sponsor,event_at);
  if act.status='approved' and act.source<>'SHOPPING_PPV' and coalesce((offer->>'eligible')::boolean,false) then
   normal_rate:=coalesce((offer->>'normal_rate')::numeric,0);
   welcome_rate:=greatest(0,.40-normal_rate);
   available:=least(act.bv,act.base_value,act.payable_price-act.company_fee)+act.company_fee;
   allocated:=act.dp*.40
     +act.gp*(coalesce((cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((cfg->>'generation_manager_rate')::numeric,.05)+coalesce((cfg->>'generation_global_rate')::numeric,.20))
     +act.bp*(coalesce((cfg->>'binary_pool_rate')::numeric,.35)+coalesce((cfg->>'single_line_cap')::numeric,.10)+coalesce((cfg->>'binary_manager_rate')::numeric,.05)+coalesce((cfg->>'binary_global_rate')::numeric,.20));
   if allocated>available+.0001 then raise exception 'Activation offer exceeds funded package amount. Review plan budgets.';end if;
   cfg:=cfg||jsonb_build_object('activation_offer_event',true,'activation_offer_event_at',event_at,'activation_offer_rate',.40,
    'activation_offer_normal_rate',normal_rate,'activation_offer_welcome_rate',welcome_rate);
  end if;
 end if;
 outcome:=private.distribute_mlm_event_before_activation_offer(member,b,oid,aid,cfg);
 if sponsor is not null and welcome_rate>0 then
  welcome_amount:=trunc(act.dp*welcome_rate,4);
  insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
  values(sponsor,'direct',aid,1,act.dp,welcome_rate,welcome_amount,welcome_amount,'MIO','activation-welcome-v1',
   jsonb_build_object('plan_rules',cfg,'bonus_component','welcome_bonus','display_label','Welcome Bonus (Sponsor)',
    'normal_sponsor_rate',normal_rate,'welcome_rate',welcome_rate,'offer_rate',.40,'offer_started_at',offer->>'starts_at','offer_ends_at',offer->>'ends_at',
    'nominal_mio',welcome_amount,'funded_mio',welcome_amount,'depth',1),
   'welcome:'||aid||':'||sponsor)
  on conflict(idempotency_key) do nothing returning id,status into tx,state;
  if tx is not null and state='posted' then
   update public.mio_wallet_accounts set balance=balance+welcome_amount,updated_at=now() where member_id=sponsor;
   if not found then raise exception 'Recipient wallet missing';end if;
   insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
   values(sponsor,welcome_amount,'bonus_credit',aid,tx,'Welcome Bonus (Sponsor)','bonus:'||tx);
  end if;
  outcome:=jsonb_set(outcome,'{direct}',to_jsonb(coalesce((outcome->>'direct')::numeric,0)+welcome_amount));
  outcome:=jsonb_set(outcome,'{direct_generation}',to_jsonb(coalesce((outcome->>'direct_generation')::numeric,0)+welcome_amount));
 end if;
 return outcome;
end;
$$;

revoke all on function private.mlm_point_candidates(uuid,numeric,numeric,jsonb),private.guard_bonus_funding(),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== supabase/migrations/20261016203000_dynamic_welcome_bonus_switch.sql =====
-- Admin-controlled Welcome Bonus availability.
-- The current setting is captured once, at a member's first approved package
-- activation, so later setting changes never alter an offer already started.
insert into public.system_config(config_key,version,config_value,effective_from)
values('WELCOME_BONUS',1,'true'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create table if not exists private.member_welcome_bonus_eligibility (
 member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
 enabled boolean not null,
 started_at timestamptz,
 ends_at timestamptz,
 decided_at timestamptz not null default clock_timestamp(),
 check ((enabled and started_at is not null and ends_at=started_at+interval '15 days')
     or (not enabled and started_at is null and ends_at is null))
);

revoke all on table private.member_welcome_bonus_eligibility from public,anon,authenticated;

-- Preserve every offer that had already started before this switch existed.
insert into private.member_welcome_bonus_eligibility(member_id,enabled,started_at,ends_at,decided_at)
select member_id,true,starts_at,starts_at+interval '15 days',clock_timestamp()
from (
 select member_id,min(coalesce(activated_at,requested_at)) starts_at
 from public.package_activations
 where status='approved'
 group by member_id
) existing
on conflict(member_id) do nothing;

create or replace function private.capture_welcome_bonus_eligibility()
returns trigger language plpgsql security definer set search_path='' as $$
declare is_enabled boolean; starts timestamptz;
begin
 if new.status<>'approved' or (tg_op='UPDATE' and old.status='approved') then return new; end if;
 if exists(select 1 from private.member_welcome_bonus_eligibility where member_id=new.member_id) then return new; end if;
 select coalesce(config_value,'true'::jsonb)='true'::jsonb into is_enabled
 from public.system_config
 where config_key='WELCOME_BONUS' and effective_to is null
 order by version desc limit 1;
 is_enabled:=coalesce(is_enabled,true);
 starts:=coalesce(new.activated_at,new.requested_at,clock_timestamp());
 insert into private.member_welcome_bonus_eligibility(member_id,enabled,started_at,ends_at)
 values(new.member_id,is_enabled,case when is_enabled then starts end,case when is_enabled then starts+interval '15 days' end)
 on conflict(member_id) do nothing;
 return new;
end $$;

drop trigger if exists capture_welcome_bonus_eligibility on public.package_activations;
create trigger capture_welcome_bonus_eligibility
after insert or update of status on public.package_activations
for each row execute function private.capture_welcome_bonus_eligibility();

create or replace function private.activation_offer_window(p_member uuid,p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
 with decision as (
  select enabled,started_at,ends_at
  from private.member_welcome_bonus_eligibility
  where member_id=p_member
 ), current_plan as (
  select private.package_eligible(p_member) eligible,
   coalesce((private.current_mlm_rules()->'plans'->private.current_package_code(p_member)->>'direct_rate')::numeric,0) normal_rate
 ), current_setting as (
  select coalesce((select config_value='true'::jsonb from public.system_config
   where config_key='WELCOME_BONUS' and effective_to is null order by version desc limit 1),true) feature_enabled
 )
 select jsonb_build_object(
  'starts_at',d.started_at,
  'ends_at',d.ends_at,
  'eligible',coalesce(c.eligible and d.enabled and p_at>=d.started_at and p_at<d.ends_at,false),
  'enabled',coalesce(d.enabled,false),
  'enrolled',d.member_id is not null,
  'feature_enabled',s.feature_enabled,
  'normal_rate',c.normal_rate,
  'offer_rate',.40
 )
 from current_plan c cross join current_setting s
 left join (select p_member member_id,decision.* from decision) d on true;
$$;

create or replace function public.admin_set_welcome_bonus(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_enabled is null then raise exception 'Choose whether the Welcome Bonus is on or off'; end if;
 perform pg_advisory_xact_lock(hashtextextended('welcome-bonus-setting',0));
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='WELCOME_BONUS';
 update public.system_config set effective_to=clock_timestamp()
 where config_key='WELCOME_BONUS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('WELCOME_BONUS',v,to_jsonb(p_enabled),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'WELCOME_BONUS_SET','system_config',jsonb_build_object('enabled',p_enabled,'version',v));
 return jsonb_build_object('enabled',p_enabled,'version',v);
end $$;

revoke all on function private.capture_welcome_bonus_eligibility(),private.activation_offer_window(uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.admin_set_welcome_bonus(boolean) from public,anon;
grant execute on function public.admin_set_welcome_bonus(boolean) to authenticated;
notify pgrst,'reload schema';


-- ===== supabase/migrations/20261016204500_founder_activation_binary_root.sql =====
-- The Founder is sponsored by the Company for the generation relationship,
-- but is the root of the member Binary tree. Activating the Founder must not
-- try to place them on the Company's LEFT or RIGHT side.
create or replace function private.place_binary_after_activation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare sponsor uuid; side text; company uuid;
begin
  if new.status <> 'approved' or not private.package_eligible(new.member_id)
     or exists (select 1 from public.binary_placements where member_id = new.member_id) then
    return new;
  end if;

  -- Company/Admin remains outside Binary even if it activates a package.
  if exists(select 1 from public.user_roles where user_id=new.member_id and role='admin') then
    return new;
  end if;

  -- The Founder becomes the Binary root on first paid activation. No side is
  -- required and the Company is recorded only as the account that placed it.
  select company_id into company
  from private.network_foundation
  where singleton and founder_id=new.member_id;
  if company is not null then
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
    values(new.member_id,null,null,company)
    on conflict(member_id) do nothing;
    return new;
  end if;

  select m.sponsor_id,u.raw_user_meta_data->>'referral_side' into sponsor,side
  from public.member_profiles m
  join auth.users u on u.id=m.user_id
  where m.user_id=new.member_id;
  if sponsor is not null and side is not null then
    perform private.place_outermost(new.member_id,sponsor,upper(side));
  end if;
  return new;
end;
$$;

revoke all on function private.place_binary_after_activation() from public,anon,authenticated;
notify pgrst,'reload schema';


-- ===== supabase/migrations/20261016213000_welcome_bonus_extra_rate_and_admin_scope.sql =====
-- Welcome Bonus is an extra percentage of the sponsor's direct DP, not a
-- top-up to a universal 40%. Existing offers use 10% on future events; already
-- posted bonuses remain immutable. Future first activations snapshot the admin rate.
insert into public.system_config(config_key,version,config_value,effective_from)
values('WELCOME_BONUS_RATE',1,'0.10'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

alter table private.member_welcome_bonus_eligibility
 add column if not exists bonus_rate numeric(8,6) not null default .10
 check (bonus_rate between 0 and .10);
update private.member_welcome_bonus_eligibility set bonus_rate=.10
 where bonus_rate is distinct from .10;

create or replace function private.capture_welcome_bonus_eligibility()
returns trigger language plpgsql security definer set search_path='' as $$
declare is_enabled boolean; starts timestamptz; configured_rate numeric;
begin
 if new.status<>'approved' or (tg_op='UPDATE' and old.status='approved') then return new; end if;
 if exists(select 1 from private.member_welcome_bonus_eligibility where member_id=new.member_id) then return new; end if;
 select coalesce(config_value,'true'::jsonb)='true'::jsonb into is_enabled
 from public.system_config where config_key='WELCOME_BONUS' and effective_to is null
 order by version desc limit 1;
 select (config_value #>> '{}')::numeric into configured_rate
 from public.system_config where config_key='WELCOME_BONUS_RATE' and effective_to is null
 order by version desc limit 1;
 is_enabled:=coalesce(is_enabled,true);
 configured_rate:=coalesce(configured_rate,.10);
 starts:=coalesce(new.activated_at,new.requested_at,clock_timestamp());
 insert into private.member_welcome_bonus_eligibility(member_id,enabled,started_at,ends_at,bonus_rate)
 values(new.member_id,is_enabled,case when is_enabled then starts end,
  case when is_enabled then starts+interval '15 days' end,configured_rate)
 on conflict(member_id) do nothing;
 return new;
end $$;

create or replace function private.activation_offer_window(p_member uuid,p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
 with decision as (
  select enabled,started_at,ends_at,bonus_rate
  from private.member_welcome_bonus_eligibility
  where member_id=p_member
 ), current_plan as (
  select private.package_eligible(p_member) eligible,
   coalesce((private.current_mlm_rules()->'plans'->private.current_package_code(p_member)->>'direct_rate')::numeric,0) normal_rate
 ), current_setting as (
  select coalesce((select config_value='true'::jsonb from public.system_config
   where config_key='WELCOME_BONUS' and effective_to is null order by version desc limit 1),true) feature_enabled
 )
 select jsonb_build_object(
  'starts_at',d.started_at,
  'ends_at',d.ends_at,
  'eligible',coalesce(c.eligible and d.enabled and p_at>=d.started_at and p_at<d.ends_at,false),
  'enabled',coalesce(d.enabled,false),
  'enrolled',d.member_id is not null,
  'feature_enabled',s.feature_enabled,
  'normal_rate',c.normal_rate,
  'welcome_rate',coalesce(d.bonus_rate,0),
  'offer_rate',c.normal_rate+coalesce(d.bonus_rate,0)
 )
 from current_plan c cross join current_setting s
 left join (select p_member member_id,decision.* from decision) d on true;
$$;

create or replace function private.distribute_mlm_event(member uuid,b numeric,oid uuid,aid uuid,cfg jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare act public.package_activations%rowtype;sponsor uuid;offer jsonb;allocated numeric;available numeric;outcome jsonb;
 normal_rate numeric:=0;target_rate numeric:=0;welcome_rate numeric:=0;welcome_amount numeric:=0;tx uuid;state text;event_at timestamptz;
begin
 cfg:=cfg-'activation_offer_event'-'activation_offer_event_at'-'activation_offer_rate'-'activation_offer_normal_rate'-'activation_offer_welcome_rate';
 if aid is not null and oid is null then
  select * into act from public.package_activations where id=aid;
  select sponsor_id into sponsor from public.member_profiles where user_id=member;
  event_at:=coalesce(act.activated_at,now());
  offer:=private.activation_offer_window(sponsor,event_at);
  if act.status='approved' and act.source<>'SHOPPING_PPV' and coalesce((offer->>'eligible')::boolean,false) then
   normal_rate:=coalesce((offer->>'normal_rate')::numeric,0);
   welcome_rate:=coalesce((offer->>'welcome_rate')::numeric,.10);
   target_rate:=normal_rate+welcome_rate;
   available:=least(act.bv,act.base_value,act.payable_price-act.company_fee)+act.company_fee;
   allocated:=act.dp*target_rate
     +act.gp*(coalesce((cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((cfg->>'generation_manager_rate')::numeric,.05)+coalesce((cfg->>'generation_global_rate')::numeric,.20))
     +act.bp*(coalesce((cfg->>'binary_pool_rate')::numeric,.35)+coalesce((cfg->>'single_line_cap')::numeric,.10)+coalesce((cfg->>'binary_manager_rate')::numeric,.05)+coalesce((cfg->>'binary_global_rate')::numeric,.20));
   if allocated>available+.0001 then raise exception 'Activation offer exceeds funded package amount. Review plan budgets.';end if;
   cfg:=cfg||jsonb_build_object('activation_offer_event',true,'activation_offer_event_at',event_at,'activation_offer_rate',target_rate,
    'activation_offer_normal_rate',normal_rate,'activation_offer_welcome_rate',welcome_rate);
  end if;
 end if;
 outcome:=private.distribute_mlm_event_before_activation_offer(member,b,oid,aid,cfg);
 if sponsor is not null and welcome_rate>0 then
  welcome_amount:=trunc(act.dp*welcome_rate,4);
  insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
  values(sponsor,'direct',aid,1,act.dp,welcome_rate,welcome_amount,welcome_amount,'MIO','activation-welcome-v1',
   jsonb_build_object('plan_rules',cfg,'bonus_component','welcome_bonus','display_label','Welcome Bonus (Sponsor)',
    'normal_sponsor_rate',normal_rate,'welcome_rate',welcome_rate,'offer_rate',target_rate,'offer_started_at',offer->>'starts_at','offer_ends_at',offer->>'ends_at',
    'nominal_mio',welcome_amount,'funded_mio',welcome_amount,'depth',1),
   'welcome:'||aid||':'||sponsor)
  on conflict(idempotency_key) do nothing returning id,status into tx,state;
  if tx is not null and state='posted' then
   update public.mio_wallet_accounts set balance=balance+welcome_amount,updated_at=now() where member_id=sponsor;
   if not found then raise exception 'Recipient wallet missing';end if;
   insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key)
   values(sponsor,welcome_amount,'bonus_credit',aid,tx,'Welcome Bonus (Sponsor)','bonus:'||tx);
  end if;
  outcome:=jsonb_set(outcome,'{direct}',to_jsonb(coalesce((outcome->>'direct')::numeric,0)+welcome_amount));
  outcome:=jsonb_set(outcome,'{direct_generation}',to_jsonb(coalesce((outcome->>'direct_generation')::numeric,0)+welcome_amount));
 end if;
 return outcome;
end;
$$;

create or replace function public.admin_set_welcome_bonus_rate(p_rate numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_rate is null or p_rate<0 or p_rate>.10 or p_rate<>round(p_rate,4)
 then raise exception 'Welcome Bonus must be between 0 and 10 percent, in 0.01 percent steps'; end if;
 perform pg_advisory_xact_lock(hashtextextended('welcome-bonus-rate-setting',0));
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='WELCOME_BONUS_RATE';
 update public.system_config set effective_to=clock_timestamp()
 where config_key='WELCOME_BONUS_RATE' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('WELCOME_BONUS_RATE',v,to_jsonb(p_rate),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'WELCOME_BONUS_RATE_SET','system_config',jsonb_build_object('rate',p_rate,'version',v));
 return jsonb_build_object('rate',p_rate,'version',v);
end $$;

revoke all on function private.capture_welcome_bonus_eligibility(),private.activation_offer_window(uuid,timestamptz),private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.admin_set_welcome_bonus_rate(numeric) from public,anon;
grant execute on function public.admin_set_welcome_bonus_rate(numeric) to authenticated;
notify pgrst,'reload schema';


-- ===== supabase/migrations/20261016214500_company_only_admin_role.sql =====
-- An admin role is effective only for the fixed company account. The Founder
-- remains its sponsored member and cannot acquire workspace access by mistake.
create or replace function private.has_role(_role public.app_role)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
  select 1 from public.user_roles r
  where r.user_id=(select auth.uid()) and r.role=_role
    and (_role<>'admin'::public.app_role or exists(
      select 1 from private.network_foundation n
      where n.singleton and n.company_id=r.user_id
    ))
 );
$$;
revoke all on function private.has_role(public.app_role) from public,anon;
grant execute on function private.has_role(public.app_role) to authenticated;
notify pgrst,'reload schema';


-- ===== supabase/migrations/20261017080000_mio_reference_price.sql =====
-- Admin controlled public reference price. This does not alter wallet or payout formulas.
insert into public.system_config(config_key,version,config_value,effective_from)
values ('MIO_REFERENCE_PRICE_PKR',1,'300'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_mio_reference_price(p_price numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_price is null or p_price<=0 or p_price>1000000 or p_price<>round(p_price,2)
 then raise exception 'Enter a price greater than zero with up to two decimal places'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-reference-price-pkr',0));
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MIO_REFERENCE_PRICE_PKR';
 update public.system_config set effective_to=clock_timestamp()
 where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('MIO_REFERENCE_PRICE_PKR',v,to_jsonb(p_price),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'MIO_REFERENCE_PRICE_SET','system_config',jsonb_build_object('price_pkr',p_price,'version',v));
 return jsonb_build_object('price_pkr',p_price,'version',v);
end $$;

revoke all on function public.admin_set_mio_reference_price(numeric) from public,anon;
grant execute on function public.admin_set_mio_reference_price(numeric) to authenticated;
notify pgrst,'reload schema';


-- ===== schema/20261020130000_binary_live_shares.sql =====
-- Package-weighted realtime binary shares used by the pool dashboard and settlement.
create or replace function private.binary_live_shares(p_end timestamptz default clock_timestamp())
returns table(
 member_id uuid,
 package_code text,
 package_version integer,
 binary_entitlement numeric,
 left_available numeric,
 right_available numeric,
 completed_shares numeric,
 consumed_each numeric
)
language sql
stable
security definer
set search_path=''
as $function$
with cfg as (
 select private.current_mlm_rules() j,private.financial_reset_at() cutoff
),ap as (
 select distinct on(a.member_id)
  a.member_id,a.package_code,a.package_version,
  coalesce((cfg.j->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) entitlement
 from public.package_activations a
 cross join cfg
 join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
 where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=p_end
 order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
),v as (
 select pl.member_id,
  coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,
  coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
 from public.point_ledger pl cross join cfg
 where pl.point_type='BP' and pl.created_at>cfg.cutoff and pl.created_at<=p_end
 group by pl.member_id
),c as (
 select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
 from public.binary_member_results r
 join public.binary_cycles bc on bc.id=r.cycle_id
 cross join cfg
 where bc.status in('posted','unallocated') and bc.created_at>cfg.cutoff
 group by r.member_id
),x as (
 select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) la,
  greatest(coalesce(v.r,0)-coalesce(c.r,0),0) ra,
  coalesce((cfg.j->>'binary_share_points_each_side')::numeric,50) sp
 from ap cross join cfg
 left join v on v.member_id=ap.member_id
 left join c on c.member_id=ap.member_id
)
select member_id,package_code,package_version,entitlement,la,ra,
 trunc(trunc(least(la,ra)/sp,1)*entitlement,4),
 trunc(least(la,ra)/sp,1)*sp
from x where sp>0
$function$;

revoke all on function private.binary_live_shares(timestamptz) from public,anon,authenticated;



-- 20261022180000: tree package-weighted binary shares
create or replace function public.my_network(
  p_kind text default 'generation',
  p_root_code text default null,
  p_depth integer default 4
)
returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare result jsonb; root uuid; parent jsonb; weighted_nodes jsonb; share_points numeric;
begin
 result:=public.my_network_before_vendor_root(p_kind,p_root_code,p_depth);
 if p_kind='vendor' then
  root:=auth.uid();
  if nullif(trim(p_root_code),'') is not null then select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-',''); end if;
  select jsonb_build_object('id',user_id,'parent_id',null,'full_name',full_name,'member_code',member_code,'depth',0,'package',private.current_package_code(user_id),'rank',achieved_rank,'status',status) into parent from public.member_profiles where user_id=root;
  result:=jsonb_set(result,'{nodes}',jsonb_build_array(parent)||coalesce(result->'nodes','[]'::jsonb));
 end if;
 share_points:=coalesce((private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,50);
 select coalesce(jsonb_agg(n.node||jsonb_build_object('binary_share_points_each_side',share_points,'binary_entitlement',coalesce(s.binary_entitlement,0),'binary_entitlement_percent',coalesce(s.binary_entitlement,0)*100,'raw_binary_shares',case when share_points>0 then trunc(least(coalesce(s.left_available,0),coalesce(s.right_available,0))/share_points,1) else 0 end,'available_binary_shares',coalesce(s.completed_shares,0)) order by n.ordinality),'[]'::jsonb) into weighted_nodes
 from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality as n(node,ordinality)
 left join private.binary_live_shares(clock_timestamp()) s on s.member_id=nullif(n.node->>'id','')::uuid;
 return jsonb_set(result,'{nodes}',weighted_nodes);
end
$function$;
revoke all on function public.my_network(text,text,integer) from public,anon;
grant execute on function public.my_network(text,text,integer) to authenticated;
notify pgrst,'reload schema';
