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
