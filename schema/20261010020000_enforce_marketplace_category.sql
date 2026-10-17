do $$
declare f text;
begin
 f:=pg_get_functiondef('public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean)'::regprocedure);
 f:=replace(f,
   $needle$or length(trim(coalesce(p_category,'')))<2 or p_price is null$needle$,
   $replacement$or length(trim(coalesce(p_category,'')))<2 or not exists(select 1 from public.system_config c cross join lateral jsonb_array_elements(c.config_value) x where c.config_key='MARKETPLACE_CATEGORIES' and c.effective_to is null and x->>'name'=trim(p_category)) or p_price is null$replacement$);
 if f not like '%MARKETPLACE_CATEGORIES%' then raise exception 'Could not enforce marketplace category selection'; end if;
 execute f;
end $$;
