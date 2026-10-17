-- Admin controlled public reference price. This does not alter wallet or payout formulas.
insert into public.system_config(config_key,version,config_value,effective_from)
values ('MIO_REFERENCE_PRICE_PKR',1,'300'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create or replace function public.admin_set_mio_reference_price(p_price numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_price is null or p_price<=0 or p_price>1000000 or p_price<>round(p_price,2)
 then raise exception 'Enter a price greater than zero with up to two decimal places'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-reference-price-pkr',0));
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MIO_REFERENCE_PRICE_PKR';
 update public.system_config set effective_to=clock_timestamp()
 where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('MIO_REFERENCE_PRICE_PKR',v,to_jsonb(p_price),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'MIO_REFERENCE_PRICE_SET','system_config',jsonb_build_object('price_pkr',p_price,'version',v));
 return jsonb_build_object('price_pkr',p_price,'version',v);
end $$;

revoke all on function public.admin_set_mio_reference_price(numeric) from public,anon;
grant execute on function public.admin_set_mio_reference_price(numeric) to authenticated;
notify pgrst,'reload schema';
