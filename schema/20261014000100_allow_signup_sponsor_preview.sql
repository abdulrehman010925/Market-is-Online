-- Registration happens before authentication, so anonymous visitors need read-only
-- access to the narrowly scoped sponsor-code lookup function.
grant execute on function public.lookup_side_referral(text) to anon, authenticated;
notify pgrst, 'reload schema';
