drop policy if exists commission_read on public.commission_allocations;
create policy commission_read on public.commission_allocations for select to authenticated
using(private.has_role('admin') or beneficiary_id=(select auth.uid()));

drop policy if exists ecommerce_read on public.ecommerce_rewards;
create policy ecommerce_read on public.ecommerce_rewards for select to authenticated
using(((beneficiary_id=(select auth.uid())) or private.has_role('admin')) and created_at>private.financial_reset_at());

drop policy if exists "buyer or operations reads Premium purchase" on public.premium_purchase_requests;
create policy "buyer or operations reads Premium purchase" on public.premium_purchase_requests for select to authenticated
using(member_id=(select auth.uid()) or private.has_role('admin'));

drop policy if exists shopping_rewards_read on public.shopping_reward_events;
create policy shopping_rewards_read on public.shopping_reward_events for select to authenticated
using(buyer_id=(select auth.uid()) or private.has_role('admin'));

drop policy if exists "active member submits seller application" on public.vendor_applications;
create policy "active member submits seller application" on public.vendor_applications for insert to authenticated
with check(applicant_user_id=(select auth.uid()) and exists(
 select 1 from public.member_profiles
 where user_id=(select auth.uid()) and status='active'
));

drop policy if exists vendor_income_read on public.vendor_income_ledger;
create policy vendor_income_read on public.vendor_income_ledger for select to authenticated
using(private.has_role('admin') or exists(
 select 1 from public.vendors v
 where v.id=vendor_income_ledger.vendor_id and v.owner_user_id=(select auth.uid())
));

drop policy if exists vendor_withdrawal_read on public.vendor_withdrawals;
create policy vendor_withdrawal_read on public.vendor_withdrawals for select to authenticated
using(private.has_role('admin') or exists(
 select 1 from public.vendors v
 where v.id=vendor_withdrawals.vendor_id and v.owner_user_id=(select auth.uid())
));
