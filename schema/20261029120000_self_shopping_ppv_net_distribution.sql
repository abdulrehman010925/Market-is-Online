-- Future PPV-mode self-shopping: deduct the configured fee from the gross
-- shopping points, pay the direct sponsor from the net base, then split the
-- remainder between the generation and binary plans. Existing events retain
-- their original snapshots. The order-level idempotency key is unchanged.
create or replace function private.shopping_ppv_cap_status(p_member uuid)
returns table(cap numeric, used numeric, remaining numeric, locked boolean)
language sql stable security definer set search_path to '' as $function$
with settings as (
  select coalesce((select coalesce((config_value->>'total_ppv_cap')::numeric,
                                   (config_value->>'shopping_ppv_cap')::numeric)
    from public.system_config where config_key='PPV_CAPS' and effective_to is null
    order by version desc limit 1),110)::numeric cap
), usage as (
  select coalesce(sum(pl.amount),0)::numeric used from public.point_ledger pl
  where pl.member_id=p_member and pl.point_type='PPV'
    and pl.created_at>private.financial_reset_at()
)
select settings.cap,usage.used,greatest(settings.cap-usage.used,0),usage.used>=settings.cap
from settings cross join usage
$function$;
revoke all on function private.shopping_ppv_cap_status(uuid) from public, anon, authenticated;
alter table public.shopping_reward_events add column if not exists brp numeric not null default 0;

-- Reconcile older local test schema with the live cap-aware order snapshot.
create or replace function private.snapshot_order_reward_mode()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare code text:=upper(trim(coalesce(current_setting('mio.affiliate_code',true),'')));
  seller uuid; cap_locked boolean:=false;
begin
  if code<>'' then
    select user_id into seller from public.member_profiles
    where (upper(member_code)=code or upper(replace(member_code,'MIO-',''))=code
      or upper(referral_code)=regexp_replace(code,'-[LR]$',''))
      and status in('active','inactive') and terms_accepted_at is not null;
    if seller is null then raise exception 'Selling link is no longer valid'; end if;
  end if;
  if seller=new.buyer_id then seller:=null; end if;
  new.selling_affiliate_id:=seller; new.reward_owner_id:=coalesce(seller,new.buyer_id);
  select case when private.package_eligible(user_id) then shopping_reward_mode else 'PPV' end,sponsor_id
    into new.reward_mode,new.reward_sponsor_id from public.member_profiles where user_id=new.reward_owner_id;
  if new.reward_owner_id is not null then
    select s.locked into cap_locked from private.shopping_ppv_cap_status(new.reward_owner_id)s;
  end if;
  if cap_locked then
    new.reward_mode:='MIO';
    update public.member_profiles set shopping_reward_mode='MIO',updated_at=now()
      where user_id=new.reward_owner_id and shopping_reward_mode<>'MIO';
  end if;
  select sponsor_id into new.reward_second_sponsor_id
    from public.member_profiles where user_id=new.reward_sponsor_id;
  new.reward_mode:=coalesce(new.reward_mode,'PPV'); return new;
end
$function$;

-- Guest-order security guarantee. Paid sellers use 2 MIO. Free sellers may
-- use 2 PPV, 2 MIO, or ask their direct sponsor to guarantee 2 MIO.
alter table public.affiliate_guest_order_approvals
  add column if not exists hold_type text,
  add column if not exists hold_amount numeric(20,4) not null default 2,
  add column if not exists hold_member_id uuid references public.member_profiles(user_id),
  add column if not exists guarantee_requested_at timestamptz,
  add column if not exists guarantee_confirmed_at timestamptz;
alter table public.affiliate_guest_order_approvals drop constraint if exists affiliate_guest_order_approvals_status_check;
alter table public.affiliate_guest_order_approvals add constraint affiliate_guest_order_approvals_status_check
  check(status in('pending','guarantee_requested','approved','rejected','released','cancelled_refunded'));
alter table public.affiliate_guest_order_approvals drop constraint if exists affiliate_guest_order_approvals_hold_type_check;
alter table public.affiliate_guest_order_approvals add constraint affiliate_guest_order_approvals_hold_type_check
  check(hold_type is null or hold_type in('MIO','PPV','SPONSOR_MIO'));

drop function if exists public.my_affiliate_guest_order_approvals();
create function public.my_affiliate_guest_order_approvals() returns table(
 order_id uuid,order_code text,status text,hold_mio numeric,hold_type text,hold_amount numeric,
 role text,is_paid boolean,available_mio numeric,available_ppv numeric,created_at timestamptz,
 approved_at timestamptz,released_at timestamptz,guest_name text,guest_city text,total_pkr numeric,
 payment_status public.payment_status,fulfillment_status public.order_status,item_count bigint
)language sql stable security definer set search_path='' as $function$
 select a.order_id,o.order_code,a.status,a.hold_mio,a.hold_type,a.hold_amount,
  case when a.sponsor_id=auth.uid() then 'SELLER' else 'GUARANTOR' end,
  exists(select 1 from public.package_activations p where p.member_id=a.sponsor_id and p.status='approved'),
  coalesce((select w.balance from public.mio_wallet_accounts w where w.member_id=auth.uid()),0),
  coalesce((select sum(l.amount) from public.point_ledger l where l.member_id=auth.uid() and l.point_type='PPV'),0),
  a.created_at,a.approved_at,a.released_at,o.shipping_name,o.shipping_city,o.total_pkr,o.payment_status,o.status,count(i.id)
 from public.affiliate_guest_order_approvals a join public.orders o on o.id=a.order_id
 left join public.order_items i on i.order_id=o.id
 where a.sponsor_id=auth.uid() or(a.status='guarantee_requested' and a.hold_member_id=auth.uid())
 group by a.order_id,o.id order by a.created_at desc
$function$;

drop function if exists public.review_affiliate_guest_order(uuid,boolean,text,text);
create function public.review_affiliate_guest_order(
 p_order_id uuid,p_approve boolean,p_transaction_pin text,p_idempotency_key text,p_hold_method text default 'MIO'
)returns jsonb language plpgsql security definer set search_path='' as $function$
declare member uuid:=auth.uid();a public.affiliate_guest_order_approvals%rowtype;o public.orders%rowtype;
 item record;paid boolean;ppv_balance numeric;direct_sponsor uuid;method text:=upper(coalesce(p_hold_method,'MIO'));
begin
 if member is null then raise exception 'Sign in first';end if;
 if length(trim(coalesce(p_idempotency_key,'')))<8 then raise exception 'Valid request reference required';end if;
 perform pg_advisory_xact_lock(hashtextextended('affiliate-approval:'||p_order_id::text,0));
 select * into a from public.affiliate_guest_order_approvals where order_id=p_order_id for update;
 if a.order_id is null or a.sponsor_id<>member then raise exception 'Affiliate order approval not found';end if;
 select * into o from public.orders where id=p_order_id for update;
 if a.status not in('pending','guarantee_requested') then return jsonb_build_object('order_id',a.order_id,'status',a.status,'hold_type',a.hold_type);end if;
 if o.status in('cancelled','returned') then raise exception 'This order is already closed';end if;
 if not p_approve then
  for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
   update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
  end loop;
  update public.orders set status='cancelled',updated_at=now() where id=o.id;
  update public.affiliate_guest_order_approvals set status='rejected',rejected_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
  return jsonb_build_object('order_id',o.id,'status','rejected');
 end if;
 select exists(select 1 from public.package_activations p where p.member_id=member and p.status='approved') into paid;
 if paid and method<>'MIO' then raise exception 'Paid members must use the 2 MIO Cash Wallet guarantee';end if;
 if method='SPONSOR' then
  if paid then raise exception 'Sponsor guarantee is available to free accounts only';end if;
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=member;
  if direct_sponsor is null then raise exception 'No direct sponsor is available for this request';end if;
  update public.affiliate_guest_order_approvals set status='guarantee_requested',hold_type='SPONSOR_MIO',hold_member_id=direct_sponsor,
   guarantee_requested_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
  return jsonb_build_object('order_id',o.id,'status','guarantee_requested');
 end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 if method='PPV' then
  if paid then raise exception 'PPV guarantee is available to free accounts only';end if;
  select coalesce(sum(amount),0) into ppv_balance from public.point_ledger where member_id=member and point_type='PPV';
  if ppv_balance<2 then raise exception 'Minimum 2 PPV is required to confirm this guest order';end if;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
   values(member,'PPV',-2,o.id,'debit','affiliate-ppv-hold:'||o.id) on conflict(idempotency_key)do nothing;
 else
  update public.mio_wallet_accounts set balance=balance-2,updated_at=now() where member_id=member and balance>=2;
  if not found then raise exception 'Cash Wallet needs 2 MIO to confirm this guest order';end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key)
   values(member,-2,'affiliate_order_hold',o.id,'Refundable guest-order security guarantee','affiliate-hold:'||o.id)on conflict(idempotency_key)do nothing;
  method:='MIO';
 end if;
 update public.affiliate_guest_order_approvals set status='approved',hold_type=method,hold_member_id=member,approved_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
 return jsonb_build_object('order_id',o.id,'status','approved','hold_type',method,'hold_amount',2);
end
$function$;

create or replace function public.review_sponsor_guest_guarantee(p_order_id uuid,p_approve boolean,p_transaction_pin text,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare member uuid:=auth.uid();a public.affiliate_guest_order_approvals%rowtype;
begin
 if member is null then raise exception 'Sign in first';end if;
 perform pg_advisory_xact_lock(hashtextextended('affiliate-approval:'||p_order_id::text,0));
 select * into a from public.affiliate_guest_order_approvals where order_id=p_order_id for update;
 if a.status<>'guarantee_requested' or a.hold_member_id<>member then raise exception 'Sponsor guarantee request not found';end if;
 if not p_approve then
  update public.affiliate_guest_order_approvals set status='pending',hold_type=null,hold_member_id=null,updated_at=now() where order_id=p_order_id;
  return jsonb_build_object('order_id',p_order_id,'status','pending');
 end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 update public.mio_wallet_accounts set balance=balance-2,updated_at=now() where member_id=member and balance>=2;
 if not found then raise exception 'Sponsor Cash Wallet needs 2 MIO for this guarantee';end if;
 insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key)
 values(member,-2,'affiliate_order_hold',p_order_id,'Refundable sponsor guest-order guarantee','affiliate-hold:'||p_order_id)on conflict(idempotency_key)do nothing;
 update public.affiliate_guest_order_approvals set status='approved',hold_type='SPONSOR_MIO',approved_at=now(),guarantee_confirmed_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=p_order_id;
 return jsonb_build_object('order_id',p_order_id,'status','approved','hold_type','SPONSOR_MIO','hold_amount',2);
end
$function$;

create or replace function private.release_affiliate_guest_hold() returns trigger
language plpgsql security definer set search_path='' as $function$
declare a public.affiliate_guest_order_approvals%rowtype;release_status text;
begin
 select * into a from public.affiliate_guest_order_approvals where order_id=new.id for update;
 if a.order_id is null or a.status<>'approved' then return new;end if;
 if new.status='delivered' and new.payment_status='confirmed' then release_status:='released';
 elsif new.status in('cancelled','returned') then release_status:='cancelled_refunded';else return new;end if;
 if a.hold_type='PPV' then
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
   values(a.hold_member_id,'PPV',a.hold_amount,new.id,'credit','affiliate-ppv-refund:'||new.id)on conflict(idempotency_key)do nothing;
 else
  update public.mio_wallet_accounts set balance=balance+a.hold_amount,updated_at=now() where member_id=a.hold_member_id;
  if not found then raise exception 'Guarantee Cash Wallet missing';end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key)
   values(a.hold_member_id,a.hold_amount,'affiliate_order_refund',new.id,'Guest-order guarantee returned','affiliate-refund:'||new.id)on conflict(idempotency_key)do nothing;
 end if;
 update public.affiliate_guest_order_approvals set status=release_status,released_at=now(),updated_at=now() where order_id=new.id;
 return new;
end
$function$;

create or replace function public.guest_order_status(p_order_code text,p_access_token text) returns jsonb
language plpgsql stable security definer set search_path='' as $function$
declare o public.orders%rowtype;a public.affiliate_guest_order_approvals%rowtype;
begin
 if length(coalesce(p_access_token,''))<32 then raise exception 'Guest order access denied';end if;
 select * into o from public.orders where upper(order_code)=upper(trim(p_order_code))and buyer_id is null and guest_access_token_hash=md5(p_access_token);
 if o.id is null then raise exception 'Guest order access denied';end if;
 select * into a from public.affiliate_guest_order_approvals where order_id=o.id;
 return jsonb_build_object('id',o.id,'order_code',o.order_code,'created_at',o.created_at,'status',o.status,'payment_status',o.payment_status,
  'sponsor_confirmation',case when a.status in('approved','released','cancelled_refunded')then 'confirmed' when a.status='guarantee_requested'then 'awaiting sponsor guarantee' else a.status end,
  'admin_confirmation',case when o.payment_status='confirmed'or o.status in('confirmed','processing','shipped','delivered')then 'confirmed' else 'pending' end,
  'security_guarantee',a.hold_type,'total_pkr',o.total_pkr,'shipping_name',o.shipping_name,'shipping_city',o.shipping_city,
  'items',coalesce((select jsonb_agg(jsonb_build_object('product_name_snapshot',i.product_name_snapshot,'quantity',i.quantity,'line_total_pkr',i.line_total_pkr)order by i.created_at)from public.order_items i where i.order_id=o.id),'[]'::jsonb));
end
$function$;

revoke all on function public.my_affiliate_guest_order_approvals(),public.review_affiliate_guest_order(uuid,boolean,text,text,text),public.review_sponsor_guest_guarantee(uuid,boolean,text,text) from public,anon;
grant execute on function public.my_affiliate_guest_order_approvals(),public.review_affiliate_guest_order(uuid,boolean,text,text,text),public.review_sponsor_guest_guarantee(uuid,boolean,text,text) to authenticated;
notify pgrst,'reload schema';

-- Treasury totals can move down while individual network bonuses are posted.
-- Record the signed reconciliation delta, but never attempt a rounded zero row.
create or replace function private.sync_company_treasury() returns void
language plpgsql security definer set search_path to '' as $function$
declare company uuid;r record;delta numeric;target numeric;
begin
 select company_id into company from private.network_foundation where singleton;
 if company is null then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('company-treasury-sync',0));
 for r in
  with expected as(select source_type,source_id,category,currency,sum(amount) amount from private.company_treasury_sources() group by 1,2,3,4)
  select coalesce(e.source_type,p.source_type) typ,coalesce(e.source_id,p.source_id) sid,
   coalesce(e.category,p.category) cat,coalesce(e.currency,p.currency) cur,
   coalesce(e.amount,0) target,coalesce(p.amount,0) previous
  from expected e full join public.company_treasury_positions p using(source_type,source_id,category,currency)
 loop
  target:=round(r.target,4);delta:=round(target-r.previous,4);
  if delta is null or abs(delta)<.0001 then continue;end if;
  insert into public.company_treasury_positions(source_type,source_id,category,currency,amount)
  values(r.typ,r.sid,r.cat,r.cur,target)
  on conflict(source_type,source_id,category,currency) do update set amount=excluded.amount,updated_at=now();
  insert into public.company_treasury_ledger(company_id,source_type,source_id,category,currency,amount)
  values(company,r.typ,r.sid,r.cat,r.cur,delta);
 end loop;
end
$function$;

create or replace function private.release_order_rewards()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare
  o public.orders%rowtype;
  ppv numeric; total numeric; funding numeric; r record; outcome jsonb;
  net_base numeric; dp_base numeric; gp_base numeric; bp_base numeric; brp_base numeric;
  direct_amount numeric; remaining_base numeric;
  fee_rate numeric := .10; cap numeric := 110; used numeric := 0;
begin
  select * into o from public.orders where id = new.id for update;
  if o.status in ('cancelled','returned') and o.rewards_credited_at is null then
    update public.ecommerce_rewards set status = 'cancelled'
    where order_id = o.id and status = 'pending_delivery';
    return new;
  end if;
  if o.status <> 'delivered' or o.payment_status <> 'confirmed' or o.rewards_credited_at is not null then return new; end if;

  select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0)
    into ppv from public.order_items where order_id=o.id;
  if o.reward_owner_id is null then
    update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;
    perform private.sync_company_treasury(); return new;
  end if;
  if o.reward_mode='PPV' then
    select s.cap,s.used into cap,used from private.shopping_ppv_cap_status(o.reward_owner_id)s;
    ppv:=least(ppv,greatest(0,cap-used));
  end if;
  if o.reward_version=1 then
    o.reward_owner_id:=o.buyer_id;
    perform private.post_shopping_rewards(o.id);
  else
    select coalesce(sum(a.amount_pkr),0) into funding
    from public.commission_allocations a join public.order_items i on i.id=a.order_item_id
    where i.order_id=o.id and a.share_kind='network_rewards';
    if ppv*300>funding then raise exception 'Order rewards exceed verified funding'; end if;
    if o.reward_mode='MIO' then
      for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop
        perform private.credit_ecommerce_reward(r.id);
      end loop;
      update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;
      perform private.sync_company_treasury(); return new;
    elsif ppv>0 then
      fee_rate:=coalesce((o.rules_snapshot->>'shopping_admin_fee_rate')::numeric,.10);
      if fee_rate<0 or fee_rate>1 then raise exception 'Invalid shopping admin fee rate'; end if;
      net_base:=trunc(ppv*(1-fee_rate),4);
      dp_base:=trunc(net_base*coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric,1),4);
      select coalesce(max(c.nominal),0) into direct_amount
      from private.mlm_point_candidates(o.reward_owner_id,dp_base,0,o.rules_snapshot)c
      where c.method='direct';
      if direct_amount<0 or direct_amount>dp_base then raise exception 'Shopping direct bonus exceeds available net base'; end if;
      remaining_base:=greatest(0,dp_base-direct_amount);
      gp_base:=trunc(remaining_base*coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric,.5),4);
      bp_base:=trunc(remaining_base*coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric,.5),4);
      brp_base:=bp_base;
      insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,dp,gp,bp,brp,binary_reserve_mio)
      values(o.id,o.reward_owner_id,funding,net_base,dp_base,gp_base,bp_base,brp_base,
        trunc(bp_base*coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric,.35),4))
      on conflict do nothing;
      if found then
        outcome:=private.distribute_mlm_event(o.reward_owner_id,dp_base,o.id,null,o.rules_snapshot);
        update public.shopping_reward_events
        set direct_generation_mio=(outcome->>'direct_generation')::numeric,
            single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;
      end if;
    end if;
  end if;
  if ppv>0 then
    insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
    values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv')
    on conflict(idempotency_key) do nothing;
  end if;
  if o.reward_mode='PPV' and used+ppv>=cap then
    update public.member_profiles set shopping_reward_mode='MIO',updated_at=now()
    where user_id=o.reward_owner_id;
  end if;
  update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;
  select coalesce(sum(amount),0) into total from public.point_ledger
  where member_id=o.reward_owner_id and point_type='PPV';
  perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);
  perform private.sync_company_treasury(); return new;
end
$function$;
