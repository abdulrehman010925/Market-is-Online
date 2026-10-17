create function public.advance_order_status(p_order_id uuid,p_status public.order_status)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; states public.order_status[]:=array['placed','confirmed','processing','shipped','delivered']::public.order_status[]; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null then raise exception 'Order not found'; end if;
 if o.status=p_status then return; end if;
 if array_position(states,p_status) is null or array_position(states,o.status) is null or array_position(states,p_status)<>array_position(states,o.status)+1 then raise exception 'Order must advance one fulfillment stage at a time'; end if;
 update public.orders set status=p_status,updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'ORDER_STATUS_CHANGED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status',p_status));
end $$;
create function public.cancel_unpaid_order(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; item record; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null or (o.buyer_id<>auth.uid() and not private.has_role('admin')) then raise exception 'Order not found'; end if;
 if o.status='cancelled' then return; end if;
 if o.payment_status<>'unconfirmed' or o.status not in('placed','confirmed','processing') or (not private.has_role('admin') and o.status<>'placed') then raise exception 'This order cannot be cancelled here; contact the company'; end if;
 for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
  update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
 end loop;
 update public.orders set status='cancelled',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'UNPAID_ORDER_CANCELLED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status','cancelled','inventory_restored',true));
end $$;
revoke all on function public.advance_order_status(uuid,public.order_status),public.cancel_unpaid_order(uuid) from public,anon;
grant execute on function public.advance_order_status(uuid,public.order_status),public.cancel_unpaid_order(uuid) to authenticated;
