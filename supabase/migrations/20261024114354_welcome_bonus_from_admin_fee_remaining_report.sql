-- Welcome Bonus is funded from the package admin fee. Report only the
-- remaining fee as company income and keep the network leftover independent.
create or replace function private.company_treasury_sources_before_ecommerce()
returns table(source_type text,source_id uuid,category text,currency text,amount numeric)
language sql stable security definer set search_path='' as $$
 with package_spend as (
  select a.id,a.company_fee,a.dp,a.gp,a.bp,a.rules_snapshot cfg,
   coalesce(sum(b.payable_amount) filter(where b.method='direct' and b.status in('posted','pending')),0) direct_paid,
   least(a.company_fee,coalesce(sum(b.payable_amount) filter(where b.method='direct' and b.status in('posted','pending')
    and (b.formula_version='activation-welcome-v1' or b.calculation_trace->>'bonus_component'='welcome_bonus')),0)) welcome_fee
  from public.package_activations a left join public.bonus_transactions b on b.source_activation_id=a.id
  where a.status='approved' and a.source<>'SHOPPING_PPV'
  group by a.id
 ), package_balances as (
  select p.id,greatest(0,p.company_fee-p.welcome_fee) net_fee,
   greatest(0,p.dp
    -p.gp*(coalesce((p.cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((p.cfg->>'generation_manager_rate')::numeric,.05)+coalesce((p.cfg->>'generation_global_rate')::numeric,.20))
    -p.bp*(coalesce((p.cfg->>'binary_pool_rate')::numeric,.35)+coalesce((p.cfg->>'single_line_cap')::numeric,.10)+coalesce((p.cfg->>'binary_manager_rate')::numeric,.05)+coalesce((p.cfg->>'binary_global_rate')::numeric,.20))
    -p.direct_paid+p.welcome_fee) network_leftover
  from package_spend p
 )
 select s.source_type,s.source_id,s.category,s.currency,
  case when s.source_type='package' and s.currency='MIO' and p.id is not null then
   case s.category when 'package_company_fee' then p.net_fee
    when 'network_formula_leftover' then p.network_leftover else s.amount end
  else s.amount end
 from private.company_treasury_sources_before_activation_offer() s
 left join package_balances p on p.id=s.source_id and s.source_type='package';
$$;

revoke all on function private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
notify pgrst,'reload schema';
