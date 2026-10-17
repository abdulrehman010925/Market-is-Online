-- A buyer using another member's selling link receives the retail discount only.
-- If that buyer is also an ancestor/introducer, their would-be share remains company leftover.
do $$declare f text;begin
 f:=pg_get_functiondef('private.prepare_order_rewards()'::regprocedure);
 f:=replace(f,'values(o.id,new.id,r.who,r.kind,r.rate,b,amt)','values(o.id,new.id,case when o.selling_affiliate_id is not null and r.who=o.buyer_id then null else r.who end,r.kind,r.rate,b,amt)');execute f;
 f:=pg_get_functiondef('private.post_network_bonus(uuid,uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric,jsonb)'::regprocedure);
 f:=replace(f,'if amount<=0 then return;end if;','if amount<=0 then return;end if; if oid is not null and exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=who) then return;end if;');execute f;
 f:=pg_get_functiondef('private.distribute_mlm_event(uuid,numeric,uuid,uuid,jsonb)'::regprocedure);
 f:=replace(f,'if oid is not null and trunc(b*.5,4)>0 then','if oid is not null and trunc(b*.5,4)>0 and not exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=p) then');execute f;
end $$;
