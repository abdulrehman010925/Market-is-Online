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

