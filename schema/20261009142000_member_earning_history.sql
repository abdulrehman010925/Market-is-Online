-- A member can request a compact, source-aware history for only their own bonuses.
create or replace function public.my_earning_history()
returns table(
 bonus_id uuid,
 method public.bonus_method,
 generation integer,
 payable_amount numeric,
 status text,
 created_at timestamptz,
 qualifying_base numeric,
 rate numeric,
 formula_version text,
 source_member_id uuid,
 source_name text,
 source_code text,
 source_package_code text,
 source_order_code text,
 source_product text,
 source_total_pkr numeric,
 source_order_status text,
 source_payment_status text,
 affiliate_name text,
 affiliate_code text,
 source_kind text,
 cycle_code text,
 calculation_trace jsonb
)
language plpgsql stable security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 return query
 select b.id,b.method,b.generation::integer,b.payable_amount,b.status::text,b.created_at,
        b.qualifying_base,b.rate,b.formula_version,
        coalesce(o.buyer_id,a.member_id),src.full_name,src.member_code,
        coalesce(a.package_code,current_plan.package_code),o.order_code,
        (select string_agg(i.product_name_snapshot,' · ' order by i.id)
           from public.order_items i where i.order_id=o.id),
        o.total_pkr,o.status::text,o.payment_status::text,
        affiliate.full_name,affiliate.member_code,
        case when o.id is not null then 'Shopping order'
             when a.id is not null then 'Plan activation'
             when b.cycle_id is not null then 'Binary pool cycle'
             else 'Network bonus' end,
        cycle.cycle_code,b.calculation_trace
 from public.bonus_transactions b
 left join public.orders o on o.id=b.source_order_id
 left join public.package_activations a on a.id=b.source_activation_id
 left join public.member_profiles src on src.user_id=coalesce(o.buyer_id,a.member_id)
 left join public.member_profiles affiliate on affiliate.user_id=o.selling_affiliate_id
 left join public.binary_cycles cycle on cycle.id=b.cycle_id
 left join lateral (
   select pa.package_code from public.package_activations pa
   where pa.member_id=o.buyer_id and pa.status='approved' and pa.activated_at<=b.created_at
   order by pa.activated_at desc,pa.requested_at desc limit 1
 ) current_plan on true
 where b.beneficiary_id=auth.uid()
 order by b.created_at desc,b.id;
end
$$;
revoke all on function public.my_earning_history() from public,anon;
grant execute on function public.my_earning_history() to authenticated;
