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
