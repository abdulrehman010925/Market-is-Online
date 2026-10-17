-- Full, paginatable personal history. The dashboard's 200-row operations preview
-- must not truncate a member's calendar or expose another recipient's earnings.
create or replace function public.my_ecommerce_history()
returns table(
 id uuid, beneficiary_id uuid, order_code text, product_name_snapshot text,
 reward_kind text, rate numeric, base_points numeric, amount numeric,
 status text, created_at timestamptz, source_name text, source_code text
)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 return query
 select e.id,e.beneficiary_id,o.order_code,i.product_name_snapshot,
        e.reward_kind,e.rate,e.base_points,e.amount,e.status,e.created_at,
        buyer.full_name,buyer.member_code
 from public.ecommerce_rewards e
 join public.orders o on o.id=e.order_id
 join public.order_items i on i.id=e.order_item_id
 left join public.member_profiles buyer on buyer.user_id=o.buyer_id
 where e.beneficiary_id=auth.uid()
 order by e.created_at desc,e.id;
end $$;
revoke all on function public.my_ecommerce_history() from public,anon;
grant execute on function public.my_ecommerce_history() to authenticated;
notify pgrst,'reload schema';
