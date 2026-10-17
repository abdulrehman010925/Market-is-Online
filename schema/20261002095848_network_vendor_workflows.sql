CREATE OR REPLACE FUNCTION private.mio_transfer(p_recipient_id uuid, p_amount numeric, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  sender_id uuid := (select auth.uid());
  transfer_key uuid := gen_random_uuid();
  sender_admin boolean;
  recipient_admin boolean;
  sender_premium boolean;
  recipient_premium boolean;
  existing_transfer uuid;
  locked_user uuid;
  wallet_balance numeric(20,4);
begin
  if sender_id is null then raise exception 'Authentication required'; end if;
  if p_recipient_id is null or p_recipient_id = sender_id then raise exception 'Choose another member'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 or p_amount <> round(p_amount,4) then raise exception 'Invalid MIO amount'; end if;
  if length(coalesce(p_idempotency_key,'')) < 12 or length(p_idempotency_key) > 100 then raise exception 'Invalid idempotency key'; end if;

  perform pg_advisory_xact_lock(hashtextextended('mio-request:'||sender_id::text||':'||p_idempotency_key,0));
  if not exists(select 1 from public.member_profiles where user_id=sender_id and status='active') or not exists(select 1 from public.member_profiles where user_id=p_recipient_id and status='active') then raise exception 'Both accounts must be active'; end if;
  select transfer_id into existing_transfer from public.mio_ledger
    where idempotency_key = sender_id::text || ':' || p_idempotency_key || ':out';
  if existing_transfer is not null then return existing_transfer; end if;

  select private.has_role('admin') into sender_admin;
  select exists(select 1 from public.user_roles r where r.user_id=p_recipient_id and r.role='admin')
    into recipient_admin;
  sender_premium := coalesce(private.current_package_code(sender_id) = 'PREMIUM',false);
  recipient_premium := coalesce(private.current_package_code(p_recipient_id) = 'PREMIUM',false);
  -- Company may send to every active member; ordinary incoming rules remain.
  if not sender_admin then
    if recipient_admin and not sender_premium then
      raise exception 'Only Premium members can send to company';
    elsif not recipient_admin and not (sender_premium or recipient_premium) then
      raise exception 'At least one member in a MIO transfer must hold the Premium package';
    end if;
  end if;

  -- Lock in a deterministic order to prevent double-spending and deadlocks.
  for locked_user in
    select member_id from public.mio_wallet_accounts
    where member_id in (sender_id, p_recipient_id) order by member_id
    for update
  loop null; end loop;
  select balance into wallet_balance from public.mio_wallet_accounts where member_id = sender_id;
  if wallet_balance is null or not exists(select 1 from public.mio_wallet_accounts where member_id=p_recipient_id) then raise exception 'Wallet not initialized'; end if;
  if wallet_balance < p_amount then raise exception 'Insufficient MIO balance'; end if;

  update public.mio_wallet_accounts set balance = balance - p_amount, updated_at = now() where member_id = sender_id;
  update public.mio_wallet_accounts set balance = balance + p_amount, updated_at = now() where member_id = p_recipient_id;
  insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,idempotency_key)
    values (sender_id,-p_amount,'transfer_out',p_recipient_id,transfer_key,sender_id::text || ':' || p_idempotency_key || ':out'),
           (p_recipient_id,p_amount,'transfer_in',sender_id,transfer_key,sender_id::text || ':' || p_idempotency_key || ':in');
  return transfer_key;
end;
$function$;

-- The company is outside the member binary tree. This registry is private.
create table private.network_foundation(singleton boolean primary key default true check(singleton),company_id uuid not null unique references public.member_profiles(user_id),founder_id uuid not null unique references public.member_profiles(user_id),check(company_id<>founder_id));
revoke all on private.network_foundation from public,anon,authenticated;
do $$declare c uuid; f uuid; begin
 select m.user_id into c from public.member_profiles m join public.user_roles r on r.user_id=m.user_id and r.role='admin' where m.full_name='Market is Online Operations';
 select user_id into f from public.member_profiles where full_name='Abdul Rehman Abbasi' and sponsor_id=c;
 if c is not null and f is not null then
  if exists(select 1 from public.binary_placements where member_id=c or (member_id=f and parent_id is not null)) then raise exception 'Existing founder placement requires review'; end if;
  if exists(select 1 from public.member_profiles where sponsor_id=c and user_id<>f) then raise exception 'Company has another direct member'; end if;
  insert into private.network_foundation values(true,c,f);
  insert into public.binary_placements(member_id,parent_id,side,placed_by) values(f,null,null,c) on conflict(member_id) do nothing;
 end if;
end $$;

create function private.guard_foundation_profile() returns trigger language plpgsql security definer set search_path='' as $$begin
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 if exists(select 1 from private.network_foundation where company_id=new.sponsor_id and founder_id<>new.user_id) then raise exception 'Company has one founder only. Use Abdul Rehman or a team referral'; end if;
 if tg_op='UPDATE' and exists(select 1 from private.network_foundation where (founder_id=new.user_id and company_id is distinct from new.sponsor_id) or (company_id=new.user_id and new.sponsor_id is not null)) then raise exception 'Company and founder relationships are permanent'; end if;
 return new;
end $$;
create trigger foundation_profile_guard before insert or update of sponsor_id on public.member_profiles for each row execute function private.guard_foundation_profile();
create function private.guard_company_binary() returns trigger language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.user_roles where user_id in(new.member_id,new.parent_id) and role='admin') then raise exception 'Company has no left/right binary placement'; end if;
 if exists(select 1 from private.network_foundation where founder_id=new.member_id) and new.parent_id is not null then raise exception 'Founder is the member binary root'; end if;
 return new;
end $$;
create trigger company_binary_guard before insert or update on public.binary_placements for each row execute function private.guard_company_binary();

-- Side is encoded in the referral code, then validated before sponsor signup.
create function private.normalize_side_referral() returns trigger language plpgsql security definer set search_path='' as $$
declare ref text:=upper(trim(coalesce(new.raw_user_meta_data->>'referral_code',''))); begin
 if ref ~ '-[LR]$' then
  new.raw_user_meta_data:=new.raw_user_meta_data||jsonb_build_object('referral_code',left(ref,length(ref)-2),'referral_side',case right(ref,1) when 'L' then 'LEFT' else 'RIGHT' end);
 end if;
 return new;
end $$;
create trigger normalize_side_referral before insert on auth.users for each row execute function private.normalize_side_referral();
create function private.place_outermost(p_member uuid,p_sponsor uuid,p_side text) returns void language plpgsql security definer set search_path='' as $$
declare parent uuid:=p_sponsor; child uuid; hops integer:=0; begin
 if p_side is null or p_side not in('LEFT','RIGHT') then raise exception 'Choose LEFT or RIGHT'; end if;
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 if exists(select 1 from public.user_roles where user_id=p_sponsor and role='admin') then raise exception 'Company has no left/right links. Use founder referral'; end if;
 if exists(select 1 from public.binary_placements where member_id=p_member) then return; end if;
 if not exists(select 1 from public.binary_placements where member_id=parent) then raise exception 'Sponsor binary position must be set first'; end if;
 loop
  select member_id into child from public.binary_placements where parent_id=parent and side=p_side;
  exit when child is null;
  parent:=child; hops:=hops+1;
  if parent=p_member or hops>10000 then raise exception 'Invalid or excessively deep binary path'; end if;
 end loop;
 insert into public.binary_placements(member_id,parent_id,side,placed_by) values(p_member,parent,p_side,p_sponsor);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(p_sponsor,'REFERRAL_BINARY_PLACED','binary_placement',p_member,jsonb_build_object('sponsor',p_sponsor,'parent',parent,'side',p_side));
end $$;
create function private.place_signup_binary() returns trigger language plpgsql security definer set search_path='' as $$declare side text; begin
 select raw_user_meta_data->>'referral_side' into side from auth.users where id=new.user_id;
 if new.status='active' and new.sponsor_id is not null and side is not null then perform private.place_outermost(new.user_id,new.sponsor_id,upper(side)); end if;
 return new;
end $$;
create trigger signup_binary_placement after insert on public.member_profiles for each row execute function private.place_signup_binary();

create function public.lookup_transfer_recipient(p_code text) returns table(member_code text,full_name text) language plpgsql stable security definer set search_path='' as $$begin
 if auth.uid() is null or not exists(select 1 from public.member_profiles where user_id=auth.uid() and status='active') then raise exception 'Active account required'; end if;
 return query select m.member_code,m.full_name from public.member_profiles m where (upper(m.member_code)=upper(trim(p_code)) or upper(m.referral_code)=upper(trim(p_code))) and m.status='active' and m.user_id<>auth.uid();
end $$;
create function public.lookup_side_referral(p_code text) returns table(member_code text,full_name text,placement_side text) language sql stable security definer set search_path='' as $$
 select m.member_code,m.full_name,case right(upper(trim(p_code)),2) when '-L' then 'LEFT' when '-R' then 'RIGHT' else null end
 from public.member_profiles m where (upper(m.referral_code)=regexp_replace(upper(trim(p_code)),'-[LR]$','') or upper(m.member_code)=regexp_replace(upper(trim(p_code)),'-[LR]$','')) and m.status='active' and not exists(select 1 from public.user_roles r where r.user_id=m.user_id and r.role='admin');
$$;

-- Single-line follows placement parents, with exact rational cumulative rounding.
create function private.credit_single_line(p_activation uuid) returns void language plpgsql security definer set search_path='' as $$
declare a public.package_activations%rowtype; r record; lim integer; pkg text; amount numeric; tx uuid; begin
 select * into a from public.package_activations where id=p_activation and status='approved';
 if a.id is null then return; end if;
 for r in with recursive up(member_id,depth,path) as (
  select b.parent_id,1,array[a.member_id,b.parent_id] from public.binary_placements b where b.member_id=a.member_id and b.parent_id is not null
  union all select b.parent_id,u.depth+1,u.path||b.parent_id from up u join public.binary_placements b on b.member_id=u.member_id where u.depth<30 and b.parent_id is not null and not b.parent_id=any(u.path)
 ) select * from up order by depth loop
  pkg:=private.current_package_code(r.member_id);
  lim:=case pkg when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 when 'PREMIUM' then 30 else 0 end;
  if r.depth>lim or not exists(select 1 from public.member_profiles where user_id=r.member_id and status='active') then continue; end if;
  amount:=round(a.bv*r.depth/300,4)-round(a.bv*(r.depth-1)/300,4);
  if amount<=0 then continue; end if;
  tx:=null;
  insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
  values(r.member_id,'single_line',a.id,r.depth,a.bv,1::numeric/300,a.bv/300,amount,'MIO','single-line-placement-v1',jsonb_build_object('rate_numerator',1,'rate_denominator',300,'placement_level',r.depth,'package',pkg,'limit',lim,'rounding','cumulative difference at 4 decimals'),'posted','single:'||a.id||':'||r.member_id) on conflict(idempotency_key) do nothing returning id into tx;
  if tx is not null then
   update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=r.member_id;
   insert into public.mio_ledger(member_id,amount,action,activation_id,bonus_transaction_id,reason,idempotency_key) values(r.member_id,amount,'bonus_credit',a.id,tx,'Single line income','bonus:'||tx);
  end if;
 end loop;
end $$;
create function private.activation_single_line() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' then perform private.credit_single_line(new.id); end if; return new;
end $$;
create trigger activation_single_line after insert on public.package_activations for each row execute function private.activation_single_line();

create function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); root uuid; is_company boolean; allowed boolean; result jsonb; begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status='active') then raise exception 'Active account required'; end if;
 if p_kind not in('generation','binary','pool','single_line','vendor') or p_depth not between 1 and 6 then raise exception 'Invalid tree view'; end if;
 is_company:=private.has_role('admin'); root:=uid;
 if is_company and p_kind in('binary','pool','single_line') then select founder_id into root from private.network_foundation where company_id=uid; end if;
 if nullif(trim(p_root_code),'') is not null then
  select user_id into root from public.member_profiles where member_code=upper(trim(p_root_code));
  with recursive team(id,path) as(select uid,array[uid] union all select m.user_id,t.path||m.user_id from team t join public.member_profiles m on m.sponsor_id=t.id where not m.user_id=any(t.path)) select exists(select 1 from team where id=root) into allowed;
  if not is_company and not allowed then
   with recursive team(id,path) as(select uid,array[uid] union all select b.member_id,t.path||b.member_id from team t join public.binary_placements b on b.parent_id=t.id where not b.member_id=any(t.path)) select exists(select 1 from team where id=root) into allowed;
   if not allowed then raise exception 'Your network only'; end if;
  end if;
 end if;
 if root is null then return jsonb_build_object('nodes','[]'::jsonb); end if;
 if p_kind='vendor' then
  return jsonb_build_object('nodes',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'parent_id',root,'full_name',v.business_name,'member_code',m.member_code,'depth',1,'commission_rate',v.commission_rate,'status',v.status)) from public.vendors v join public.member_profiles m on m.user_id=v.owner_user_id where m.sponsor_id=root),'[]'::jsonb));
 end if;
 with recursive tree(id,parent_id,side,depth,path) as (
  select root,null::uuid,null::text,0,array[root]
  union all select m.user_id, t.id,case when p_kind='generation' then null else b.side end,t.depth+1,t.path||m.user_id from tree t join public.member_profiles m on
   (p_kind='generation' and m.sponsor_id=t.id) or (p_kind<>'generation' and exists(select 1 from public.binary_placements x where x.member_id=m.user_id and x.parent_id=t.id))
   left join public.binary_placements b on b.member_id=m.user_id where t.depth<p_depth and not m.user_id=any(t.path)
 ), bounded as(select * from tree order by depth,id limit 501)
 select jsonb_build_object('truncated',count(*)>500,'nodes',coalesce(jsonb_agg(jsonb_build_object('id',t.id,'parent_id',t.parent_id,'side',t.side,'depth',t.depth,'member_code',m.member_code,'full_name',m.full_name,'status',m.status,'package',private.current_package_code(t.id),
 'bp',coalesce((select bp from public.package_activations a where a.member_id=t.id and a.status='approved' order by base_value desc,activated_at desc limit 1),0),
 'left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT'),0)-coalesce((select sum(consumed_left) from public.binary_member_results where member_id=t.id),0),
 'right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT'),0)-coalesce((select sum(consumed_right) from public.binary_member_results where member_id=t.id),0)) order by t.depth,t.side,t.id) filter(where t.id in(select id from bounded limit 500)),'[]'::jsonb)) into result from bounded t join public.member_profiles m on m.user_id=t.id;
 return result;
end $$;
-- Pending onboarding uses the same side code and placement policy.
alter function public.complete_referral_join(text,text,text,boolean) set schema private;
revoke all on function private.complete_referral_join(text,text,text,boolean) from public,anon,authenticated;
create function public.complete_referral_join(p_full_name text,p_phone text,p_referral_code text,p_consent boolean) returns void language plpgsql security definer set search_path='' as $$declare ref text:=upper(trim(p_referral_code)); side text; sponsor uuid; begin
 if ref ~ '-[LR]$' then side:=case right(ref,1) when 'L' then 'LEFT' else 'RIGHT' end;ref:=left(ref,length(ref)-2); end if;
 perform private.complete_referral_join(p_full_name,p_phone,ref,p_consent);
 select sponsor_id into sponsor from public.member_profiles where user_id=auth.uid();
 if side is not null then perform private.place_outermost(auth.uid(),sponsor,side); end if;
end $$;

alter function public.admin_review_vendor_application(uuid,boolean) set schema private;
revoke all on function private.admin_review_vendor_application(uuid,boolean) from public,anon,authenticated;
create function public.admin_review_vendor_application(p_application_id uuid,p_approve boolean,p_commission_rate numeric default null) returns uuid language plpgsql security definer set search_path='' as $$declare v uuid; begin
 if p_approve and (p_commission_rate is null or p_commission_rate<0 or p_commission_rate>1 or p_commission_rate<>round(p_commission_rate,6)) then raise exception 'Set this vendor commission at approval'; end if;
 v:=private.admin_review_vendor_application(p_application_id,p_approve);
 if p_approve then perform public.set_vendor_commission(v,p_commission_rate); end if;
 return v;
end $$;

alter table public.products add column ppv_per_unit numeric(18,4) check(ppv_per_unit>=0 and ppv_per_unit<=1000000);
alter table public.order_items add column ppv_per_unit_snapshot numeric(18,4);
create function private.guard_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 if (tg_op='INSERT' and new.ppv_per_unit is not null) or (tg_op='UPDATE' and new.ppv_per_unit is distinct from old.ppv_per_unit) then
  if not private.has_role('admin') then raise exception 'Only company review assigns product PPV'; end if;
 end if;
 return new;
end $$;
create trigger guard_product_ppv before insert or update on public.products for each row execute function private.guard_product_ppv();
alter function public.admin_review_product(uuid,boolean) set schema private;
revoke all on function private.admin_review_product(uuid,boolean) from public,anon,authenticated;
create function public.admin_review_product(p_product_id uuid,p_approve boolean,p_ppv numeric default null) returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_approve and (p_ppv is null or p_ppv<0 or p_ppv>1000000 or p_ppv<>round(p_ppv,4)) then raise exception 'Assign PPV to this product before approval'; end if;
 perform private.admin_review_product(p_product_id,p_approve);
 if p_approve then update public.products set ppv_per_unit=p_ppv where id=p_product_id; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_PPV_REVIEWED','product',p_product_id,jsonb_build_object('approved',p_approve,'ppv_per_unit',p_ppv));
end $$;
create function private.snapshot_item_ppv() returns trigger language plpgsql security definer set search_path='' as $$begin
 select ppv_per_unit into new.ppv_per_unit_snapshot from public.products where id=new.product_id;
 if new.ppv_per_unit_snapshot is null then raise exception 'Product PPV is awaiting company review'; end if;
 return new;
end $$;
create trigger snapshot_item_ppv before insert on public.order_items for each row execute function private.snapshot_item_ppv();
-- Existing approved listings require PPV review; existing orders retain history.
update public.products set status='pending' where status='approved' and ppv_per_unit is null;

create or replace function public.admin_confirm_order_payment(p_order_id uuid)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  admin_id uuid := (select auth.uid());
  order_row public.orders%rowtype;
  ppv_value numeric(18,4);
  current_ppv numeric(18,4);
  activated integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  select * into order_row from public.orders where id=p_order_id for update;
  if order_row.id is null then raise exception 'Order not found'; end if;
  if order_row.payment_status='confirmed' then return order_row.ppv_generated; end if;
  if order_row.payment_status<>'unconfirmed' or order_row.status in ('cancelled','returned') then
    raise exception 'Order is not eligible for payment confirmation';
  end if;
  select coalesce(sum(coalesce(ppv_per_unit_snapshot,unit_price_pkr/order_row.usd_to_pkr_rate)*quantity),0) into ppv_value from public.order_items where order_id=order_row.id;
  ppv_value:=round(ppv_value,4);
  update public.orders set payment_status='confirmed',ppv_generated=ppv_value,updated_at=now() where id=order_row.id;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
    values(order_row.buyer_id,'PPV',ppv_value,order_row.id,'credit','order:' || order_row.id::text || ':ppv')
    on conflict(idempotency_key) do nothing;
  select coalesce(sum(amount),0) into current_ppv from public.point_ledger
    where member_id=order_row.buyer_id and point_type='PPV';
  activated := private.activate_next_ppv_package(order_row.buyer_id,order_row.id,current_ppv);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(admin_id,'ORDER_PAYMENT_CONFIRMED','order',order_row.id,
      jsonb_build_object('buyer_id',order_row.buyer_id,'ppv_generated',ppv_value,'cumulative_ppv',current_ppv,'auto_activations',activated));
  return ppv_value;
end;
$$;

-- Seller proceeds are PKR and remain separate from MIO member earnings.
create table public.vendor_income_ledger(id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.vendors(id),order_item_id uuid unique references public.order_items(id),gross_pkr numeric(18,2) not null,commission_pkr numeric(18,2) not null,net_pkr numeric(18,2) not null check(net_pkr=gross_pkr-commission_pkr),created_at timestamptz not null default now());
create index vendor_income_vendor_idx on public.vendor_income_ledger(vendor_id,created_at desc);
alter table public.vendor_income_ledger enable row level security;
create policy vendor_income_read on public.vendor_income_ledger for select to authenticated using(private.has_role('admin') or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=auth.uid()));
grant select on public.vendor_income_ledger to authenticated;
revoke insert,update,delete on public.vendor_income_ledger from anon,authenticated;
create function private.post_vendor_sale() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr)
  select i.vendor_id,i.id,i.line_total_pkr,round(i.line_total_pkr*i.commission_rate_snapshot,2),i.line_total_pkr-round(i.line_total_pkr*i.commission_rate_snapshot,2) from public.order_items i where i.order_id=new.id on conflict(order_item_id) do nothing;
 end if;
 return new;
end $$;
create trigger post_vendor_sale after update of payment_status on public.orders for each row execute function private.post_vendor_sale();
create table public.vendor_withdrawals(id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.vendors(id),amount_pkr numeric(18,2) not null check(amount_pkr>0),bank_name text not null,account_name text not null,account_number text not null,status text not null default 'pending' check(status in('pending','approved','paid','rejected')),idempotency_key text not null,review_note text,reviewed_by uuid references auth.users(id),created_at timestamptz not null default now(),reviewed_at timestamptz,unique(vendor_id,idempotency_key));
create index vendor_withdrawals_status_idx on public.vendor_withdrawals(vendor_id,status);
alter table public.vendor_withdrawals enable row level security;
create policy vendor_withdrawal_read on public.vendor_withdrawals for select to authenticated using(private.has_role('admin') or exists(select 1 from public.vendors v where v.id=vendor_id and v.owner_user_id=auth.uid()));
grant select on public.vendor_withdrawals to authenticated;
revoke insert,update,delete on public.vendor_withdrawals from anon,authenticated;
create function public.request_vendor_withdrawal(p_amount numeric,p_bank text,p_account_name text,p_account_number text,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare vid uuid; available numeric; wid uuid; begin
 select id into vid from public.vendors where owner_user_id=auth.uid() and status='active' for update;
 if vid is null then raise exception 'Active seller required'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>1000000000 then raise exception 'Invalid withdrawal amount'; end if;
 if length(trim(coalesce(p_bank,''))) not between 2 and 100 or length(trim(coalesce(p_account_name,''))) not between 2 and 150 or length(trim(coalesce(p_account_number,''))) not between 5 and 100 or length(coalesce(p_idempotency_key,'')) not between 12 and 100 then raise exception 'Complete your bank details'; end if;
 select id into wid from public.vendor_withdrawals where vendor_id=vid and idempotency_key=p_idempotency_key;
 if wid is not null then return wid; end if;
 select coalesce((select sum(net_pkr) from public.vendor_income_ledger where vendor_id=vid),0)-coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=vid and status in('pending','approved','paid')),0) into available;
 if p_amount>available then raise exception 'Insufficient available seller income'; end if;
 insert into public.vendor_withdrawals(vendor_id,amount_pkr,bank_name,account_name,account_number,idempotency_key) values(vid,p_amount,trim(p_bank),trim(p_account_name),trim(p_account_number),p_idempotency_key) returning id into wid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_WITHDRAWAL_REQUESTED','vendor_withdrawal',wid,jsonb_build_object('vendor_id',vid,'amount_pkr',p_amount));
 return wid;
end $$;
create function public.review_vendor_withdrawal(p_request_id uuid,p_status text,p_note text) returns void language plpgsql security definer set search_path='' as $$declare w public.vendor_withdrawals%rowtype; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 select * into w from public.vendor_withdrawals where id=p_request_id for update;
 if w.id is null then raise exception 'Withdrawal not found'; end if;
 if p_status not in('approved','paid','rejected') or length(trim(coalesce(p_note,'')))<10 or length(p_note)>2000 then raise exception 'Choose a valid decision and record payment reference or reason'; end if;
 if w.status=p_status then return; end if;
 if not ((w.status='pending' and p_status in('approved','rejected')) or (w.status='approved' and p_status in('paid','rejected'))) then raise exception 'Invalid withdrawal transition'; end if;
 update public.vendor_withdrawals set status=p_status,review_note=trim(p_note),reviewed_by=auth.uid(),reviewed_at=now() where id=w.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'VENDOR_WITHDRAWAL_REVIEWED','vendor_withdrawal',w.id,jsonb_build_object('status',w.status),jsonb_build_object('status',p_status,'note',trim(p_note),'amount',w.amount_pkr));
end $$;
create function public.my_vendor_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$declare vid uuid; begin
 select id into vid from public.vendors where owner_user_id=auth.uid() and status='active';
 if vid is null then return null; end if;
 return jsonb_build_object('sales_pkr',coalesce((select sum(gross_pkr) from public.vendor_income_ledger where vendor_id=vid),0),'commission_pkr',coalesce((select sum(commission_pkr) from public.vendor_income_ledger where vendor_id=vid),0),'income_pkr',coalesce((select sum(net_pkr) from public.vendor_income_ledger where vendor_id=vid),0),'reserved_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=vid and status in('pending','approved')),0),'paid_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where vendor_id=vid and status='paid'),0));
end $$;
-- No company left/right volume; incentives retain their existing ledger sources.
create function public.company_network_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 return jsonb_build_object('founder',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.founder_id where n.company_id=auth.uid()),'binary_retention_mio',coalesce((select sum(company_retention) from public.binary_member_results),0),'seller_commission_pkr',coalesce((select sum(commission_pkr) from public.vendor_income_ledger),0),'package_fees_mio',coalesce((select sum(company_fee) from public.package_activations where status='approved'),0));
end $$;

revoke all on function private.guard_foundation_profile(),private.guard_company_binary(),private.normalize_side_referral(),private.place_outermost(uuid,uuid,text),private.place_signup_binary(),private.credit_single_line(uuid),private.activation_single_line(),private.guard_product_ppv(),private.snapshot_item_ppv(),private.post_vendor_sale() from public,anon,authenticated;
revoke all on function public.lookup_transfer_recipient(text),public.lookup_side_referral(text),public.complete_referral_join(text,text,text,boolean),public.my_network(text,text,integer),public.admin_review_vendor_application(uuid,boolean,numeric),public.admin_review_product(uuid,boolean,numeric),public.request_vendor_withdrawal(numeric,text,text,text,text),public.review_vendor_withdrawal(uuid,text,text),public.my_vendor_summary(),public.company_network_summary() from public,anon;
grant execute on function public.lookup_transfer_recipient(text),public.complete_referral_join(text,text,text,boolean),public.my_network(text,text,integer),public.admin_review_vendor_application(uuid,boolean,numeric),public.admin_review_product(uuid,boolean,numeric),public.request_vendor_withdrawal(numeric,text,text,text,text),public.review_vendor_withdrawal(uuid,text,text),public.my_vendor_summary(),public.company_network_summary() to authenticated;
grant execute on function public.lookup_side_referral(text) to anon,authenticated;
