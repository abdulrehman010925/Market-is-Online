-- Delivery and verified payment jointly release personal and network rewards.
alter table public.orders add column rewards_credited_at timestamptz;
update public.orders set rewards_credited_at=updated_at where ppv_generated>0;
alter function private.post_shopping_rewards(uuid) rename to post_shopping_rewards_delivered;
create function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.orders where id=oid and status='delivered' and payment_status='confirmed') then perform private.post_shopping_rewards_delivered(oid);end if;
end $$;
create function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;ppv numeric;total numeric;begin
 select * into o from public.orders where id=new.id for update;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.buyer_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 perform private.post_shopping_rewards(o.id);
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;
 select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.buyer_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.buyer_id,o.id,total);
 return new;
end $$;
-- Alphabetical trigger ordering ensures vendor funding is reserved before reward release.
create trigger zz_release_order_rewards after update of status,payment_status on public.orders for each row execute function private.release_order_rewards();
create or replace function public.admin_confirm_order_payment(p_order_id uuid) returns numeric language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null then raise exception 'Order not found';end if;
 if o.payment_status='confirmed' then return o.ppv_generated;end if;
 if o.payment_status<>'unconfirmed' or o.status in ('cancelled','returned') then raise exception 'Order is not eligible for payment confirmation';end if;
 update public.orders set payment_status='confirmed',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'ORDER_PAYMENT_CONFIRMED','order',o.id,jsonb_build_object('buyer_id',o.buyer_id,'delivery_status',o.status));
 return (select ppv_generated from public.orders where id=o.id);
end $$;
revoke all on function private.post_shopping_rewards_delivered(uuid),private.post_shopping_rewards(uuid),private.release_order_rewards() from public,anon,authenticated;
