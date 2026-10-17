-- An admin role is effective only for the fixed company account. The Founder
-- remains its sponsored member and cannot acquire workspace access by mistake.
create or replace function private.has_role(_role public.app_role)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
  select 1 from public.user_roles r
  where r.user_id=(select auth.uid()) and r.role=_role
    and (_role<>'admin'::public.app_role or exists(
      select 1 from private.network_foundation n
      where n.singleton and n.company_id=r.user_id
    ))
 );
$$;
revoke all on function private.has_role(public.app_role) from public,anon;
grant execute on function private.has_role(public.app_role) to authenticated;
notify pgrst,'reload schema';
