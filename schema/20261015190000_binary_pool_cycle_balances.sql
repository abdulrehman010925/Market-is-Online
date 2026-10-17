-- Binary pool may be distributed at any time. The current-cycle inflow resets
-- after every distribution, while lifetime and wallet totals remain visible.
create or replace function public.admin_binary_pool_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 admin_id uuid:=auth.uid(); cutoff timestamptz:=private.financial_reset_at();
 last_end timestamptz; period_start timestamptz; period_end timestamptz:=clock_timestamp();
 total_generated numeric:=0; total_distributed numeric:=0; pool_wallet numeric:=0;
 current_cycle_balance numeric:=0; last_distributed numeric:=0; total_shares numeric:=0;
 package_json jsonb:='[]'::jsonb; cfg jsonb; share_points numeric;
begin
 if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 cfg:=private.current_mlm_rules();
 share_points:=coalesce((cfg->>'binary_share_points_each_side')::numeric,50);
 if share_points<=0 then share_points:=50; end if;

 select max(ends_at) into last_end from public.binary_cycles
 where status in('posted','unallocated') and created_at>cutoff;
 period_start:=coalesce(last_end,cutoff);

 select coalesce((select sum(binary_reserve_mio) from public.package_activations
   where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)
  +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)
 into total_generated;
 select coalesce(sum(pool_amount),0) into total_distributed from public.binary_cycles
 where status in('posted','unallocated') and created_at>cutoff;
 pool_wallet:=greatest(0,total_generated-total_distributed);

 select coalesce((select sum(binary_reserve_mio) from public.package_activations
   where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>period_start),0)
  +coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>period_start),0)
 into current_cycle_balance;

 select coalesce(sum(completed_shares),0) into total_shares from private.binary_live_shares(period_end);
 select coalesce(jsonb_agg(jsonb_build_object('package_code',package_code,'shares',shares) order by package_code),'[]'::jsonb)
 into package_json from (
  select package_code,sum(completed_shares) shares from private.binary_live_shares(period_end)
  group by package_code having sum(completed_shares)>0
 ) q;
 select coalesce(pool_amount,0) into last_distributed from public.binary_cycles
 where status='posted' and created_at>cutoff order by ends_at desc limit 1;

 return jsonb_build_object(
  'total_pool_generated',total_generated,
  'total_distributed',total_distributed,
  'total_pool_wallet',pool_wallet,
  'current_cycle_balance',current_cycle_balance,
  'last_distributed',last_distributed,
  'total_shares',total_shares,
  'shares_by_package',package_json,
  'share_points_each_side',share_points,
  'period_start',period_start,
  'period_end',period_end,
  'can_distribute',total_shares>0 and pool_wallet>0,
  'default_share_value',0,
  'next_cycle_code','ONDEMAND-'||to_char(period_end at time zone 'Asia/Karachi','YYYYMMDD-HH24MISS')
 );
end$$;

revoke all on function public.admin_binary_pool_dashboard() from public,anon;
grant execute on function public.admin_binary_pool_dashboard() to authenticated;
notify pgrst,'reload schema';
