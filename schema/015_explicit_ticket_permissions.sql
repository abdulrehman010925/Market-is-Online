-- Hosted Supabase defaults can grant function execution directly to anon.
revoke all on function public.answer_recovery_ticket(uuid,text,boolean) from public,anon;
grant execute on function public.answer_recovery_ticket(uuid,text,boolean) to authenticated;
