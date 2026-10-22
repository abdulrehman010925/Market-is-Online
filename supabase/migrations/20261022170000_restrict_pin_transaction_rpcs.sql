-- PIN-protected money movement must never be callable by anonymous/public roles.
revoke all on function public.mio_transfer_to_member_code(text,numeric,text,text) from public,anon;
revoke all on function public.mio_transfer(uuid,numeric,text,text) from public,anon;
revoke all on function public.activate_package_with_mio(text,text,text) from public,anon;
grant execute on function public.mio_transfer_to_member_code(text,numeric,text,text) to authenticated;
grant execute on function public.mio_transfer(uuid,numeric,text,text) to authenticated;
grant execute on function public.activate_package_with_mio(text,text,text) to authenticated;
revoke all on function public.current_user_is_admin() from public,anon;
grant execute on function public.current_user_is_admin() to authenticated;
notify pgrst,'reload schema';
