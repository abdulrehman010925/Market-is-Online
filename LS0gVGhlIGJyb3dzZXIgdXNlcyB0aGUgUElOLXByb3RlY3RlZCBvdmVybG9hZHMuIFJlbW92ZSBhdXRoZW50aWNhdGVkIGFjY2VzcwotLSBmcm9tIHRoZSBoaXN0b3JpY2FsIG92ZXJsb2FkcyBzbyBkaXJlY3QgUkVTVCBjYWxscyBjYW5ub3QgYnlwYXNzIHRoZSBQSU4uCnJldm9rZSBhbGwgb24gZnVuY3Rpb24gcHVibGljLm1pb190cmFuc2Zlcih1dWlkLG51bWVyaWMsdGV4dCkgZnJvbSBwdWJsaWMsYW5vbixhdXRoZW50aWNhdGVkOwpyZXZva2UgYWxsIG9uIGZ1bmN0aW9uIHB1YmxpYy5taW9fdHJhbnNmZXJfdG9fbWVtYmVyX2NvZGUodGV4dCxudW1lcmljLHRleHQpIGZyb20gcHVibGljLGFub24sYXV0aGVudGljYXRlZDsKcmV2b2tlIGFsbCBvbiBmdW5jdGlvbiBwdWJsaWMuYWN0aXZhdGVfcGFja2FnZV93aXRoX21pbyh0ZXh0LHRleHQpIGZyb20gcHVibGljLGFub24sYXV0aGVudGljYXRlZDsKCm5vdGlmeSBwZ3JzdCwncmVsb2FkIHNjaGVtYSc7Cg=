-- The browser uses the PIN-protected overloads. Remove authenticated access
-- from the historical overloads so direct REST calls cannot bypass the PIN.
revoke all on function public.mio_transfer(uuid,numeric,text) from public,anon,authenticated;
revoke all on function public.mio_transfer_to_member_code(text,numeric,text) from public,anon,authenticated;
revoke all on function public.activate_package_with_mio(text,text) from public,anon,authenticated;

notify pgrst,'reload schema';
