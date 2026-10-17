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
