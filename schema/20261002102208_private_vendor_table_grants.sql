-- Supabase defaults may grant table access on creation. Bank details are private.
revoke all on public.vendor_income_ledger,public.vendor_withdrawals from public,anon;
grant select on public.vendor_income_ledger,public.vendor_withdrawals to authenticated;
notify pgrst, 'reload schema';
