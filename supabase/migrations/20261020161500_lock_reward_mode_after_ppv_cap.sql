-- Keep future shopping and affiliate rewards on MIO after the 110 PPV cap.
create or replace function private.release_order_rewards()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  o public.orders%rowtype;
  ppv numeric;
  total numeric;
  funding numeric;
  r record;
  outcome jsonb;
  dp_base numeric;
  gp_base numeric;
  bp_base numeric;
  cap numeric := 110;
  used numeric := 0;
begin
  select * into o from public.orders where id = new.id for update;
  if o.status in ('cancelled', 'returned') and o.rewards_credited_at is null then
    update public.ecommerce_rewards set status = 'cancelled' where order_id = o.id and status = 'pending_delivery';
    return new;
  end if;
  if o.status <> 'delivered' or o.payment_status <> 'confirmed' or o.rewards_credited_at is not null then
    return new;
  end if;

  select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot, unit_price_pkr / o.usd_to_pkr_rate) * quantity, 4)), 0)
    into ppv
  from public.order_items
  where order_id = o.id;

  if o.reward_owner_id is null then
    update public.orders set rewards_credited_at = now(), ppv_generated = 0 where id = o.id;
    perform private.sync_company_treasury();
    return new;
  end if;

  if o.reward_mode = 'PPV' then
    select coalesce((
      select (config_value->>'shopping_ppv_cap')::numeric
      from public.system_config
      where config_key = 'PPV_CAPS' and effective_to is null
      order by version desc
      limit 1
    ), 110) into cap;

    select coalesce(sum(pl.amount), 0)
      into used
    from public.point_ledger pl
    where pl.member_id = o.reward_owner_id
      and pl.point_type = 'PPV'
      and pl.source_order_id is not null
      and pl.amount > 0
      and pl.created_at > private.financial_reset_at();

    ppv := least(ppv, greatest(0, cap - used));
  end if;

  if o.reward_version = 1 then
    o.reward_owner_id := o.buyer_id;
    perform private.post_shopping_rewards(o.id);
  else
    select coalesce(sum(a.amount_pkr), 0)
      into funding
    from public.commission_allocations a
    join public.order_items i on i.id = a.order_item_id
    where i.order_id = o.id and a.share_kind = 'network_rewards';

    if ppv * 300 > funding then raise exception 'Order rewards exceed verified funding'; end if;

    if o.reward_mode = 'MIO' then
      for r in select id from public.ecommerce_rewards where order_id = o.id order by id loop
        perform private.credit_ecommerce_reward(r.id);
      end loop;
      update public.orders set rewards_credited_at = now(), ppv_generated = 0 where id = o.id;
      perform private.sync_company_treasury();
      return new;
    elsif ppv > 0 then
      dp_base := trunc(ppv * coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric, 1), 4);
      gp_base := trunc(dp_base * coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric, .5), 4);
      bp_base := trunc(dp_base * coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric, .5), 4);

      insert into public.shopping_reward_events(
        order_id, buyer_id, funded_pkr, bv, dp, gp, bp, binary_reserve_mio
      ) values (
        o.id, o.reward_owner_id, funding, ppv, dp_base, gp_base, bp_base,
        trunc(bp_base * coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric, .35), 4)
      ) on conflict do nothing;

      if found then
        outcome := private.distribute_mlm_event(o.reward_owner_id, ppv, o.id, null, o.rules_snapshot);
        update public.shopping_reward_events
        set direct_generation_mio = (outcome->>'direct_generation')::numeric,
            single_line_mio = (outcome->>'single_line')::numeric
        where order_id = o.id;
      end if;
    end if;
  end if;

  if ppv > 0 then
    insert into public.point_ledger(
      member_id, point_type, amount, source_order_id, entry_kind, idempotency_key
    ) values (
      o.reward_owner_id, 'PPV', ppv, o.id, 'credit', 'order:' || o.id::text || ':ppv'
    ) on conflict (idempotency_key) do nothing;
  end if;

  if o.reward_mode = 'PPV' and used + ppv >= cap then
    update public.member_profiles
    set shopping_reward_mode = 'MIO', updated_at = now()
    where user_id = o.reward_owner_id;
  end if;

  update public.orders
  set ppv_generated = ppv, rewards_credited_at = now()
  where id = o.id;

  select coalesce(sum(amount), 0)
    into total
  from public.point_ledger
  where member_id = o.reward_owner_id and point_type = 'PPV';

  perform private.activate_next_ppv_package(o.reward_owner_id, o.id, total);
  perform private.sync_company_treasury();
  return new;
end
$function$;
