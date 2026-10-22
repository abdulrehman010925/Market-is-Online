-- Shared financial reset boundary used by points, pool and dashboard reports.
-- No reset is applied until FINANCIAL_RESET is explicitly configured.
create or replace function private.financial_reset_at()
returns timestamptz
language sql
stable
security definer
set search_path=''
as $$
 select coalesce(
  (select (config_value->>'reset_at')::timestamptz
   from public.system_config
   where config_key='FINANCIAL_RESET' and effective_to is null
   order by version desc limit 1),
  '-infinity'::timestamptz
 );
$$;

revoke all on function private.financial_reset_at() from public,anon,authenticated;

