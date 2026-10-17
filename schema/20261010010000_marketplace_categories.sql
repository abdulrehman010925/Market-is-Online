insert into public.system_config(config_key,version,config_value,effective_from)
values('MARKETPLACE_CATEGORIES',1,'[{"name":"Electronics & Accessories","slug":"electronics","icon":"electronics"},{"name":"Women’s Fashion","slug":"womens-fashion","icon":"womens-fashion"},{"name":"Men’s Fashion","slug":"mens-fashion","icon":"mens-fashion"},{"name":"Home & Living","slug":"home-living","icon":"home-living"},{"name":"Beauty & Personal Care","slug":"beauty","icon":"beauty"},{"name":"Health & Wellness","slug":"health","icon":"health"},{"name":"Grocery & Food","slug":"grocery","icon":"grocery"},{"name":"Sports & Outdoors","slug":"sports","icon":"sports"},{"name":"Toys & Baby","slug":"toys","icon":"toys"},{"name":"Books & Stationery","slug":"books","icon":"books"},{"name":"Automotive","slug":"automotive","icon":"automotive"},{"name":"Jewellery & Accessories","slug":"jewellery","icon":"jewellery"},{"name":"Hair & beard care","slug":"hair-beard-care","icon":"beauty"},{"name":"Skincare","slug":"skincare","icon":"skincare"},{"name":"Skincare bundles","slug":"skincare-bundles","icon":"beauty"}]'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_marketplace_categories(p_categories jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer; row jsonb; names text[]; slugs text[];
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if jsonb_typeof(p_categories)<>'array' or jsonb_array_length(p_categories)<3 or jsonb_array_length(p_categories)>40 then raise exception 'Add between 3 and 40 product categories'; end if;
 select array_agg(trim(value->>'name')),array_agg(trim(value->>'slug')) into names,slugs from jsonb_array_elements(p_categories);
 if exists(select 1 from unnest(names) n where n is null or length(n) not between 2 and 60) or
    exists(select 1 from unnest(slugs) s where s !~ '^[a-z0-9]+(-[a-z0-9]+)*$') or
    cardinality(names)<>(select count(distinct lower(n)) from unnest(names) n) or
    cardinality(slugs)<>(select count(distinct s) from unnest(slugs) s) then raise exception 'Category names and IDs must be valid and unique'; end if;
 if exists(select 1 from (select distinct category from public.products) p where not (p.category=any(names))) then raise exception 'Keep every category currently used by a product'; end if;
 if exists(select 1 from jsonb_array_elements(p_categories) x where coalesce(x->>'icon','') !~ '^[a-z0-9-]+$') then raise exception 'Choose a valid category icon'; end if;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_CATEGORIES';
 update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_CATEGORIES' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MARKETPLACE_CATEGORIES',v,p_categories,clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_CATEGORIES_SAVED','system_config',jsonb_build_object('version',v,'count',jsonb_array_length(p_categories)));
 return jsonb_build_object('version',v,'categories',jsonb_array_length(p_categories));
end $$;
revoke all on function public.admin_set_marketplace_categories(jsonb) from public,anon;
grant execute on function public.admin_set_marketplace_categories(jsonb) to authenticated;

