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
