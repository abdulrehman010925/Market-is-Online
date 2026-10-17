do $$declare f text;begin
 f:=pg_get_functiondef('public.my_network_before_vendor_root(text,text,integer)'::regprocedure);
 f:=replace(f,'''package'',private.current_package_code(t.id),''rank'',m.achieved_rank,''joined_at'',m.created_at,','''package'',private.current_package_code(t.id),''rank'',m.achieved_rank,''joined_at'',m.created_at,''profile_photo_url'',m.profile_photo_url,');
 execute f;
end $$;
notify pgrst,'reload schema';
