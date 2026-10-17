-- Keep relationship lookups indexed for the expected early member scale.
create index if not exists audit_logs_actor_idx on public.audit_logs(actor_id);
create index if not exists binary_member_results_member_idx on public.binary_member_results(member_id);
create index if not exists binary_member_results_package_idx on public.binary_member_results(package_code,package_version);
create index if not exists binary_placements_placed_by_idx on public.binary_placements(placed_by);
create index if not exists bonus_transactions_cycle_idx on public.bonus_transactions(cycle_id);
create index if not exists bonus_transactions_activation_idx on public.bonus_transactions(source_activation_id);
create index if not exists featured_products_selected_by_idx on public.featured_products(selected_by);
create index if not exists mio_ledger_activation_idx on public.mio_ledger(activation_id);
create index if not exists mio_ledger_bonus_idx on public.mio_ledger(bonus_transaction_id);
create index if not exists mio_ledger_counterparty_idx on public.mio_ledger(counterparty_id);
create index if not exists mio_ledger_cycle_idx on public.mio_ledger(cycle_id);
create index if not exists order_items_order_idx on public.order_items(order_id);
create index if not exists order_items_product_idx on public.order_items(product_id);
create index if not exists package_activations_approver_idx on public.package_activations(approved_by);
create index if not exists package_activations_package_idx on public.package_activations(package_code,package_version);
create index if not exists point_ledger_activation_idx on public.point_ledger(source_activation_id);
create index if not exists point_ledger_order_idx on public.point_ledger(source_order_id);
create index if not exists system_config_creator_idx on public.system_config(created_by);
create index if not exists vendor_applications_reviewer_idx on public.vendor_applications(reviewed_by);
create index if not exists vendors_reviewer_idx on public.vendors(reviewed_by);
create index if not exists wallet_ledger_bonus_idx on public.wallet_ledger(bonus_transaction_id);

drop policy if exists "active vendors are public" on public.vendors;
drop policy if exists "vendor owner and admins read vendor record" on public.vendors;
create policy "active vendors are public" on public.vendors for select to anon using (status='active');
create policy "authenticated reads public or own vendors" on public.vendors for select to authenticated
  using (status='active' or owner_user_id=(select auth.uid()) or private.has_role('admin'));

drop policy if exists "approved products are public" on public.products;
drop policy if exists "vendor owner and admins read product records" on public.products;
create policy "approved products are public" on public.products for select to anon
  using (status='approved' and exists(select 1 from public.vendors v where v.id=vendor_id and v.status='active'));
create policy "authenticated reads public or own products" on public.products for select to authenticated
  using ((status='approved' and exists(select 1 from public.vendors v where v.id=vendor_id and v.status='active'))
    or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=(select auth.uid()))
    or private.has_role('admin'));

revoke execute on function private.current_package_code(uuid) from authenticated;

create or replace function public.my_direct_referrals()
returns table(member_code text,full_name text,created_at timestamptz,status public.account_status)
language sql stable security definer set search_path = '' as $$
  select mp.member_code,mp.full_name,mp.created_at,mp.status
  from public.member_profiles mp
  where (select auth.uid()) is not null and mp.sponsor_id=(select auth.uid())
  order by mp.created_at desc;
$$;
revoke all on function public.my_direct_referrals() from public, anon;
grant execute on function public.my_direct_referrals() to authenticated;
