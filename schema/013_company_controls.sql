alter table public.vendors add column commission_rate numeric(7,6) check(commission_rate between 0 and 1);
alter table public.order_items add column commission_rate_snapshot numeric(7,6);
insert into public.system_config(config_key,version,config_value,effective_from) values('DELIVERY',1,'{"fee_pkr":null,"policy":null}',now());
create function public.set_company_delivery(p_fee numeric,p_policy text) returns void language plpgsql security definer set search_path='' as $$
declare ver integer; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_fee is null or p_fee<0 or p_fee>100000 or p_fee<>round(p_fee,2) or length(trim(coalesce(p_policy,'')))<10 then raise exception 'Enter a valid shipping charge and delivery policy'; end if;
 perform pg_advisory_xact_lock(hashtextextended('delivery-config',0));
 select coalesce(max(version),0)+1 into ver from public.system_config where config_key='DELIVERY';
 update public.system_config set effective_to=now() where config_key='DELIVERY' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('DELIVERY',ver,jsonb_build_object('fee_pkr',p_fee,'policy',trim(p_policy)),now(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'DELIVERY_CONFIGURED','system_config',jsonb_build_object('version',ver,'fee_pkr',p_fee));
end $$;
create function public.set_vendor_commission(p_vendor_id uuid,p_rate numeric) returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_rate is null or p_rate<0 or p_rate>1 or p_rate<>round(p_rate,6) then raise exception 'Commission must be between 0 and 100 percent'; end if;
 update public.vendors set commission_rate=p_rate where id=p_vendor_id and status='active';
 if not found then raise exception 'Active seller not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_COMMISSION_SET','vendor',p_vendor_id,jsonb_build_object('rate',p_rate));
end $$;
alter function public.place_marketplace_order(jsonb,text,text,text,text,text) set schema private;
revoke all on function private.place_marketplace_order(jsonb,text,text,text,text,text) from public,anon,authenticated;
create function public.place_marketplace_order(p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare oid uuid; fee numeric; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended('order-policy:'||auth.uid()::text||':'||p_idempotency_key,0));
 select id into oid from public.orders where buyer_id=auth.uid() and idempotency_key=p_idempotency_key;
 if oid is not null then return oid; end if;
 select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
 if fee is null then raise exception 'Delivery charges are awaiting company configuration'; end if;
 if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid) join public.products p on p.id=x.product_id join public.vendors v on v.id=p.vendor_id where v.commission_rate is null) then raise exception 'A seller is awaiting contract configuration'; end if;
 oid:=private.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 update public.orders set delivery_fee_pkr=fee,total_pkr=subtotal_pkr+fee where id=oid;
 update public.order_items i set commission_rate_snapshot=v.commission_rate from public.vendors v where i.order_id=oid and i.vendor_id=v.id;
 return oid;
end $$;
revoke all on function public.set_company_delivery(numeric,text),public.set_vendor_commission(uuid,numeric),public.place_marketplace_order(jsonb,text,text,text,text,text) from public,anon;
grant execute on function public.set_company_delivery(numeric,text),public.set_vendor_commission(uuid,numeric),public.place_marketplace_order(jsonb,text,text,text,text,text) to authenticated;

-- An operations password can change only after a fresh verified portal request.
create table private.operator_password_permits(user_id uuid primary key,expires_at timestamptz not null);
revoke all on private.operator_password_permits from public,anon,authenticated;
create function public.authorize_operator_password_change() returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 insert into private.operator_password_permits values(auth.uid(),now()+interval '30 seconds') on conflict(user_id) do update set expires_at=excluded.expires_at;
end $$;
revoke all on function public.authorize_operator_password_change() from public,anon;
grant execute on function public.authorize_operator_password_change() to authenticated;
create function private.guard_operator_password() returns trigger language plpgsql security definer set search_path='' as $$begin
 if (to_jsonb(new)->>'encrypted_password') is distinct from (to_jsonb(old)->>'encrypted_password') and exists(select 1 from public.user_roles where user_id=new.id and role='admin') then
  delete from private.operator_password_permits where user_id=new.id and expires_at>now();
  if not found then raise exception 'Change this password from the verified workspace'; end if;
 end if; return new;
end $$;
revoke all on function private.guard_operator_password() from public,anon,authenticated;
create trigger guard_operator_password before update on auth.users for each row execute function private.guard_operator_password();
