-- Keep binary tree and member dashboard share values aligned with the
-- package-weighted share engine used by the admin binary pool.
create or replace function public.my_network(
  p_kind text default 'generation',
  p_root_code text default null,
  p_depth integer default 4
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  result jsonb;
  root uuid;
  parent jsonb;
  weighted_nodes jsonb;
  share_points numeric;
begin
  result := public.my_network_before_vendor_root(p_kind, p_root_code, p_depth);

  if p_kind = 'vendor' then
    root := auth.uid();
    if nullif(trim(p_root_code), '') is not null then
      select user_id into root
      from public.member_profiles
      where member_code = 'MIO-' || regexp_replace(upper(trim(p_root_code)), '^MIO-', '');
    end if;

    select jsonb_build_object(
      'id', user_id,
      'parent_id', null,
      'full_name', full_name,
      'member_code', member_code,
      'depth', 0,
      'package', private.current_package_code(user_id),
      'rank', achieved_rank,
      'status', status
    ) into parent
    from public.member_profiles
    where user_id = root;

    result := jsonb_set(
      result,
      '{nodes}',
      jsonb_build_array(parent) || coalesce(result->'nodes', '[]'::jsonb)
    );
  end if;

  share_points := coalesce(
    (private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,
    50
  );

  select coalesce(jsonb_agg(
    n.node || jsonb_build_object(
      'binary_share_points_each_side', share_points,
      'binary_entitlement', coalesce(s.binary_entitlement, 0),
      'binary_entitlement_percent', coalesce(s.binary_entitlement, 0) * 100,
      'raw_binary_shares', case
        when share_points > 0 then trunc(
          least(coalesce(s.left_available, 0), coalesce(s.right_available, 0)) / share_points,
          1
        )
        else 0
      end,
      'available_binary_shares', coalesce(s.completed_shares, 0)
    ) order by n.ordinality
  ), '[]'::jsonb)
  into weighted_nodes
  from jsonb_array_elements(coalesce(result->'nodes', '[]'::jsonb))
    with ordinality as n(node, ordinality)
  left join private.binary_live_shares(clock_timestamp()) s
    on s.member_id = nullif(n.node->>'id', '')::uuid;

  return jsonb_set(result, '{nodes}', weighted_nodes);
end
$function$;

revoke all on function public.my_network(text, text, integer) from public, anon;
grant execute on function public.my_network(text, text, integer) to authenticated;

notify pgrst, 'reload schema';
