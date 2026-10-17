-- Initial inventory and restock entry policy; checkout depletion remains normal.
alter table public.products alter column stock_quantity set default 300;
create function private.guard_stock_entry() returns trigger language plpgsql security invoker set search_path='' as $$ begin
 if current_user in('authenticated','anon') and (tg_op='INSERT' or new.stock_quantity is distinct from old.stock_quantity) and new.stock_quantity<200 then
  raise exception 'Stock entries require at least 200 units; default stock is 300';
 end if;
 return new;
end $$;
create trigger guard_stock_entry before insert or update of stock_quantity on public.products for each row execute function private.guard_stock_entry();
revoke all on function private.guard_stock_entry() from public,anon,authenticated;
-- Trusted inventory RPCs validate entry quantities; order reservation does not use these.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean)'::regprocedure);
 f:=replace(f,'p_stock<0','p_stock<200');
 f:=replace(f,'Complete product details, positive PKR price and up to eight photos','Complete product details, positive PKR price, at least 200 stock units and up to eight photos');
 execute f;
 f:=pg_get_functiondef('public.update_seller_inventory(uuid,numeric,integer)'::regprocedure);
 f:=replace(f,'p_stock<0','p_stock<200');
 f:=replace(f,'Invalid price or stock quantity','Enter a valid price and at least 200 stock units');
 execute f;
end $$;
notify pgrst,'reload schema';
