-- Package-weighted realtime binary shares used by the pool dashboard and settlement.
create or replace function private.binary_live_shares(p_end timestamptz default clock_timestamp())
returns table(
 member_id uuid,
 package_code text,
 package_version integer,
 binary_entitlement numeric,
 left_available numeric,
 right_available numeric,
 completed_shares numeric,
 consumed_each numeric
)
language sql
stable
security definer
set search_path=''
as $function$
with cfg as (
 select private.current_mlm_rules() j,private.financial_reset_at() cutoff
),ap as (
 select distinct on(a.member_id)
  a.member_id,a.package_code,a.package_version,
  coalesce((cfg.j->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) entitlement
 from public.package_activations a
 cross join cfg
 join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active'
 where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=p_end
 order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
),v as (
 select pl.member_id,
  coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,
  coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
 from public.point_ledger pl cross join cfg
 where pl.point_type='BP' and pl.created_at>cfg.cutoff and pl.created_at<=p_end
 group by pl.member_id
),c as (
 select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
 from public.binary_member_results r
 join public.binary_cycles bc on bc.id=r.cycle_id
 cross join cfg
 where bc.status in('posted','unallocated') and bc.created_at>cfg.cutoff
 group by r.member_id
),x as (
 select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) la,
  greatest(coalesce(v.r,0)-coalesce(c.r,0),0) ra,
  coalesce((cfg.j->>'binary_share_points_each_side')::numeric,50) sp
 from ap cross join cfg
 left join v on v.member_id=ap.member_id
 left join c on c.member_id=ap.member_id
)
select member_id,package_code,package_version,entitlement,la,ra,
 trunc(trunc(least(la,ra)/sp,1)*entitlement,4),
 trunc(least(la,ra)/sp,1)*sp
from x where sp>0
$function$;

revoke all on function private.binary_live_shares(timestamptz) from public,anon,authenticated;

