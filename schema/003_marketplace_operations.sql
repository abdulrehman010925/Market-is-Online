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
