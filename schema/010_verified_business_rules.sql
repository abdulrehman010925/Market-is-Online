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

