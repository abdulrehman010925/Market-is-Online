-- Human-readable order references and source-aware member receipts.
alter table public.orders add column if not exists legacy_order_code text;
update public.orders
set legacy_order_code=coalesce(legacy_order_code,order_code),
    order_code='ORD-'||to_char(created_at at time zone 'UTC','YYMMDD')||'-'||upper(substr(replace(id::text,'-',''),1,10))
where order_code not like 'ORD-%';

create or replace function private.assign_order_reference()
returns trigger language plpgsql security definer set search_path=''
as $$begin
 new.order_code:='ORD-'||to_char(coalesce(new.created_at,now()) at time zone 'UTC','YYMMDD')||'-'||upper(substr(replace(new.id::text,'-',''),1,10));
 return new;
end$$;
drop trigger if exists assign_order_reference on public.orders;
create trigger assign_order_reference before insert on public.orders for each row execute function private.assign_order_reference();

create or replace function public.lookup_my_bonus_receipt(p_bonus_id uuid)
returns table(
 bonus_id uuid, method public.bonus_method, generation integer, payable_amount numeric,
 status text, created_at timestamptz, qualifying_base numeric, rate numeric, formula_version text,
 source_order_id uuid, source_activation_id uuid, cycle_id uuid,
 source_name text, source_code text, source_order_code text, source_product text, source_kind text
)
language plpgsql stable security definer set search_path=''
as $$begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.bonus_transactions b where b.id=p_bonus_id and b.beneficiary_id=auth.uid()) then
  raise exception 'Earning record not found for this account';
 end if;
 return query
 select b.id,b.method,b.generation::integer,b.payable_amount,b.status::text,b.created_at,b.qualifying_base,b.rate,b.formula_version,
        b.source_order_id,b.source_activation_id,b.cycle_id,
        m.full_name,m.member_code,o.order_code,
        (select string_agg(i.product_name_snapshot,' · ' order by i.id) from public.order_items i where i.order_id=o.id),
        case when o.id is not null then 'Shopping order' when a.id is not null then 'Plan activation' when b.cycle_id is not null then 'Binary pool cycle' else 'Network bonus' end
 from public.bonus_transactions b
 left join public.orders o on o.id=b.source_order_id
 left join public.package_activations a on a.id=b.source_activation_id
 left join public.member_profiles m on m.user_id=coalesce(o.reward_owner_id,o.buyer_id,a.member_id)
 where b.id=p_bonus_id and b.beneficiary_id=auth.uid();
end$$;
revoke all on function public.lookup_my_bonus_receipt(uuid) from public,anon;
grant execute on function public.lookup_my_bonus_receipt(uuid) to authenticated;

create or replace function public.admin_set_marketplace_banners(p_banners jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$declare v integer; row jsonb; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if jsonb_typeof(p_banners)<>'array' or jsonb_array_length(p_banners)>6 then raise exception 'Add no more than six banner images'; end if;
 for row in select value from jsonb_array_elements(p_banners) loop
  if jsonb_typeof(row)<>'object' or coalesce(row->>'image_url','') !~ '^https://' or length(coalesce(row->>'title',''))>90 or length(coalesce(row->>'subtitle',''))>180 then raise exception 'Each banner needs a public HTTPS image and short text'; end if;
  if coalesce(row->>'cta_link','')<>'' and row->>'cta_link' !~ '^(#|https://)' then raise exception 'Banner button must use a site section or HTTPS link'; end if;
 end loop;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_HERO';
 update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_HERO' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MARKETPLACE_HERO',v,p_banners,clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_BANNERS_SAVED','system_config',jsonb_build_object('version',v,'slide_count',jsonb_array_length(p_banners)));
 return jsonb_build_object('version',v,'slides',jsonb_array_length(p_banners));
end$$;
revoke all on function public.admin_set_marketplace_banners(jsonb) from public,anon;
grant execute on function public.admin_set_marketplace_banners(jsonb) to authenticated;

do $$begin
 if to_regclass('storage.buckets') is not null then
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
   values('marketplace-banners','marketplace-banners',true,5242880,array['image/jpeg','image/png','image/webp'])
   on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
  execute 'drop policy if exists marketplace_banners_public_read on storage.objects';
  execute 'create policy marketplace_banners_public_read on storage.objects for select using(bucket_id=''marketplace-banners'')';
  execute 'drop policy if exists marketplace_banners_admin_insert on storage.objects';
  execute 'create policy marketplace_banners_admin_insert on storage.objects for insert to authenticated with check(bucket_id=''marketplace-banners'' and private.has_role(''admin''))';
  execute 'drop policy if exists marketplace_banners_admin_update on storage.objects';
  execute 'create policy marketplace_banners_admin_update on storage.objects for update to authenticated using(bucket_id=''marketplace-banners'' and private.has_role(''admin'')) with check(bucket_id=''marketplace-banners'' and private.has_role(''admin''))';
  execute 'drop policy if exists marketplace_banners_admin_delete on storage.objects';
  execute 'create policy marketplace_banners_admin_delete on storage.objects for delete to authenticated using(bucket_id=''marketplace-banners'' and private.has_role(''admin''))';
 end if;
end$$;
