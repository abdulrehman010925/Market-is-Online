insert into public.system_config(config_key,version,config_value,effective_from)
values('MARKETPLACE_FEATURED_CATEGORIES',1,'[]'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

drop policy if exists "featured approved products are public" on public.featured_products;
create policy "featured approved products are public" on public.featured_products
for select to anon,authenticated using (
  exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
    where p.id=product_id and p.status='approved' and p.stock_quantity>0 and v.status='active')
);

create or replace function public.set_featured_products(p_product_ids uuid[])
returns integer language plpgsql security definer set search_path='' as $$
declare admin_id uuid:=auth.uid(); n integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if coalesce(array_length(p_product_ids,1),0)>6 then raise exception 'Select at most six featured products'; end if;
  if (select count(distinct x) from unnest(coalesce(p_product_ids,'{}'::uuid[])) x)<>coalesce(array_length(p_product_ids,1),0) then
    raise exception 'Duplicate featured product';
  end if;
  if exists(select 1 from unnest(coalesce(p_product_ids,'{}'::uuid[])) x
    where not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
      where p.id=x and p.status='approved' and p.stock_quantity>0 and v.status='active')) then
    raise exception 'Choose approved products from active vendors';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('mio-featured-products',0));
  delete from public.featured_products;
  insert into public.featured_products(position,product_id,selected_by)
    select ordinality::smallint,product_id,admin_id from unnest(coalesce(p_product_ids,'{}'::uuid[])) with ordinality u(product_id,ordinality);
  n:=coalesce(array_length(p_product_ids,1),0);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'FEATURED_PRODUCTS_SET','featured_products',jsonb_build_object('count',n,'product_ids',p_product_ids));
  return n;
end $$;
revoke all on function public.set_featured_products(uuid[]) from public,anon;
grant execute on function public.set_featured_products(uuid[]) to authenticated;

create or replace function public.admin_set_featured_categories(p_categories jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer; item jsonb; cat text; ids uuid[]; pid uuid;
begin
  if not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_categories)<>'array' or jsonb_array_length(p_categories)<>3 then
    raise exception 'Select exactly three featured categories';
  end if;
  if (select count(distinct value->>'category') from jsonb_array_elements(p_categories))<>3 then
    raise exception 'Choose three different categories';
  end if;
  for item in select value from jsonb_array_elements(p_categories) loop
    cat:=trim(coalesce(item->>'category',''));
    if cat='' or jsonb_typeof(item->'product_ids')<>'array' or jsonb_array_length(item->'product_ids')<>3 then
      raise exception 'Choose exactly three products for each category';
    end if;
    ids:=array(select value::uuid from jsonb_array_elements_text(item->'product_ids'));
    if cardinality(ids)<>3 or (select count(distinct x) from unnest(ids) x)<>3 then
      raise exception 'Each category must have three different products';
    end if;
    foreach pid in array ids loop
      if not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
        where p.id=pid and p.category=cat and p.status='approved' and p.stock_quantity>0 and v.status='active') then
        raise exception 'Featured products must be approved, active, and belong to their selected category';
      end if;
    end loop;
  end loop;
  select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_FEATURED_CATEGORIES';
  update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_FEATURED_CATEGORIES' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
    values('MARKETPLACE_FEATURED_CATEGORIES',v,p_categories,clock_timestamp(),auth.uid());
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(auth.uid(),'FEATURED_CATEGORIES_SAVED','system_config',jsonb_build_object('version',v,'categories',p_categories));
  return jsonb_build_object('version',v,'categories',jsonb_array_length(p_categories));
end $$;
revoke all on function public.admin_set_featured_categories(jsonb) from public,anon;
grant execute on function public.admin_set_featured_categories(jsonb) to authenticated;
