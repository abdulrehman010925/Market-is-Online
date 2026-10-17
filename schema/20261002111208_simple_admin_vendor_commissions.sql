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
