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
