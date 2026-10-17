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
