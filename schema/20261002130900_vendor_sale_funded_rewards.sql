-- Percentages below are percentages of discounted merchandise sale, excluding shipping.
alter table public.vendors drop constraint company_commission_zero;
alter table public.vendors add column sale_distribution jsonb;
alter table public.order_items add column distribution_basis text not null default 'legacy_commission';
alter table public.commission_allocations drop constraint commission_allocations_share_kind_check;
alter table public.commission_allocations add constraint commission_allocations_share_kind_check check(share_kind in('company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'));
alter table public.commission_allocations drop constraint commission_allocations_status_check;
alter table public.commission_allocations add constraint commission_allocations_status_check check(status in('discount_applied','earned','held','paid','reserved'));

create function private.valid_sale_distribution(p jsonb, rate numeric) returns boolean language plpgsql immutable set search_path='' as $$
declare k text; total numeric:=0; x numeric; begin
 if p is null or jsonb_typeof(p)<>'object' or (select count(*) from jsonb_object_keys(p))<>8 or rate is null or rate<0.05 or rate>1 then return false; end if;
 foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'] loop
  x:=(p->>k)::numeric; if x is null or x<0 or x>100 or x<>round(x,4) then return false; end if; total:=total+x;
 end loop;
 return (p->>'company')::numeric=5 and total=rate*100;
exception when others then return false; end $$;
create or replace function private.guard_company_commission() returns trigger language plpgsql security definer set search_path='' as $$ begin
 if new.is_company_owned and coalesce(new.commission_rate,0)=0 then new.commission_rate:=0.05; end if;
 if new.commission_rate>=0.05 and not private.valid_sale_distribution(new.sale_distribution,new.commission_rate) then
  new.sale_distribution:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',0,'unallocated',new.commission_rate*100-5);
 end if; return new; end $$;
update public.vendors set commission_rate=0.05 where is_company_owned;
update public.vendors set sale_distribution=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',0,'unallocated',commission_rate*100-5) where commission_rate>=0.05;
update public.vendors set commission_rate=0.30,sale_distribution='{"company":5,"buyer_discount":0,"affiliate":0,"sponsor":0,"second_upline":0,"introducer":0,"network_rewards":25,"unallocated":0}' where is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%';

create function public.set_vendor_sale_distribution(p_vendor_id uuid,p_split jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r numeric; before_row jsonb; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 select commission_rate,to_jsonb(v) into r,before_row from public.vendors v where id=p_vendor_id for update;
 if not private.valid_sale_distribution(p_split,r) then raise exception 'Company must receive 5%% of sale; all sale percentages must total the agreed commission'; end if;
 update public.vendors set sale_distribution=p_split where id=p_vendor_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'VENDOR_SALE_DISTRIBUTION','vendor',p_vendor_id,before_row,p_split);
end $$;
create or replace function public.set_commission_split(p_split jsonb) returns void language plpgsql security definer set search_path='' as $$ begin raise exception 'Select a vendor and configure percentages of sale'; end $$;
create or replace function public.set_vendor_commission(p_vendor_id uuid,p_rate numeric) returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if p_rate is null or p_rate<0.05 or p_rate>1 or p_rate<>round(p_rate,6) then raise exception 'Agreed commission must cover company 5 percent of sale'; end if;
 update public.vendors set commission_rate=p_rate,sale_distribution=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',0,'unallocated',p_rate*100-5) where id=p_vendor_id;
 if not found then raise exception 'Vendor not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_COMMISSION','vendor',p_vendor_id,jsonb_build_object('rate',p_rate,'remaining','held until vendor distribution saved'));
end $$;

create or replace function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$
declare v public.vendors%rowtype; aff text; begin
 select * into v from public.vendors where id=new.vendor_id;
 if not private.valid_sale_distribution(v.sale_distribution,v.commission_rate) then raise exception 'Vendor sale distribution is awaiting company review'; end if;
 new.company_owned_snapshot:=v.is_company_owned; new.commission_rate_snapshot:=v.commission_rate;
 new.commission_split_snapshot:=v.sale_distribution; new.distribution_basis:='sale_v2';
 new.commission_pool_pkr:=round(new.unit_price_pkr*new.quantity*v.commission_rate,2);
 new.buyer_discount_pkr:=least(round(new.unit_price_pkr*new.quantity*(v.sale_distribution->>'buyer_discount')::numeric/100,2),greatest(0,new.commission_pool_pkr-round(new.unit_price_pkr*new.quantity*0.05,2)));
 aff:=nullif(current_setting('mio.affiliate_code',true),'');
 -- Product affiliate is separate from the buyer's permanent sponsor genealogy.
 if aff is not null then
  select user_id,sponsor_id into new.affiliate_id_snapshot,new.sponsor_id_snapshot from public.member_profiles where status='active' and (upper(member_code)=upper(aff) or upper(referral_code)=upper(aff));
  if new.affiliate_id_snapshot is null then raise exception 'Affiliate code not found'; end if;
  if new.affiliate_id_snapshot=(select buyer_id from public.orders where id=new.order_id) then raise exception 'Buyer cannot claim their own affiliate sale'; end if;
  select sponsor_id into new.second_upline_id_snapshot from public.member_profiles where user_id=new.sponsor_id_snapshot;
 end if;
 new.introducer_id_snapshot:=v.introduced_by; return new;
end $$;

create table public.shopping_reward_events(
 order_id uuid primary key references public.orders(id),buyer_id uuid not null references public.member_profiles(user_id),
 funded_pkr numeric(18,2) not null check(funded_pkr>=0),bv numeric(18,4) not null check(bv>=0),
 direct_generation_mio numeric(18,4) not null default 0,single_line_mio numeric(18,4) not null default 0,
 binary_reserve_mio numeric(18,4) not null,created_at timestamptz not null default now(),
 check(direct_generation_mio>=0 and direct_generation_mio<=trunc(bv*0.55,4)),
 check(single_line_mio>=0 and single_line_mio<=trunc(bv*0.10,4)),
 check(binary_reserve_mio=trunc(bv*0.35,4)),
 check((direct_generation_mio+single_line_mio+binary_reserve_mio)*300<=funded_pkr));
alter table public.shopping_reward_events enable row level security;
create policy shopping_rewards_read on public.shopping_reward_events for select to authenticated using(buyer_id=auth.uid() or private.has_role('admin'));
revoke all on public.shopping_reward_events from public,anon,authenticated;
grant select on public.shopping_reward_events to authenticated;
create index shopping_rewards_buyer_time on public.shopping_reward_events(buyer_id,created_at);
create index shopping_rewards_time on public.shopping_reward_events(created_at);
alter table public.bonus_transactions add column source_order_id uuid references public.orders(id);
create index bonus_order_source on public.bonus_transactions(source_order_id) where source_order_id is not null;
alter table public.bonus_transactions drop constraint bonus_transactions_check;
alter table public.bonus_transactions add constraint bonus_source_check check((method='binary_pool_share' and cycle_id is not null and num_nonnulls(source_activation_id,source_order_id)=0) or (method<>'binary_pool_share' and cycle_id is null and num_nonnulls(source_activation_id,source_order_id)=1));
alter table public.mio_ledger add column source_order_id uuid references public.orders(id);
create index mio_order_source on public.mio_ledger(source_order_id) where source_order_id is not null;
alter table public.mio_ledger drop constraint mio_ledger_bonus_source_check;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check check((action in('package_activation','bonus_credit') and num_nonnulls(activation_id,cycle_id,source_order_id)=1) or (action not in('package_activation','bonus_credit') and num_nonnulls(activation_id,cycle_id,source_order_id)=0));

-- Shared list of qualified sponsor rewards. Gen1 never stacks with direct.
create function private.sale_reward_candidates(member uuid,bv numeric) returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric) language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path)
 ), recipients as(
  select u.*,p.max_generations from up u join public.member_profiles m on m.user_id=u.id and m.status='active'
  cross join lateral(select pv.max_generations from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version where a.member_id=u.id and a.status='approved' order by a.activated_at desc,a.requested_at desc limit 1)p where u.depth>0
 ) select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
 bv*case when depth=1 then coalesce((select pv.direct_rate from public.package_versions pv where pv.package_code=coalesce(private.current_package_code(member),'BASIC_1') and pv.is_active order by version desc limit 1),0.20) else 0.05 end from recipients where depth=1 or depth<=max_generations;
$$;
create function private.post_shopping_bonus(oid uuid,beneficiary uuid,method public.bonus_method,depth integer,base numeric,nominal numeric,amount numeric) returns void language plpgsql security definer set search_path='' as $$
declare tx uuid; begin
 if amount<=0 then return; end if;
 insert into public.bonus_transactions(beneficiary_id,method,source_order_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
 values(beneficiary,method,oid,depth,base,case when base>0 then amount/base else 0 end,nominal,amount,'MIO','sale-funded-v2',jsonb_build_object('sale_budget_pkr_per_mio',300,'nominal_mio',nominal,'funded_payable_mio',amount,'method_cap',case when method='single_line' then 0.10 else 0.55 end),'shopping:'||oid||':'||method||':'||beneficiary||':'||depth) on conflict(idempotency_key) do nothing returning id into tx;
 if tx is not null then
  update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=beneficiary;
  if not found then raise exception 'Recipient wallet missing'; end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,bonus_transaction_id,reason,idempotency_key) values(beneficiary,amount,'bonus_credit',oid,tx,'Shopping BV funded bonus','bonus:'||tx);
 end if;
end $$;
create function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$
declare buyer uuid; funding numeric; b numeric; r record; total numeric; scale numeric; paid numeric:=0; single_paid numeric:=0; amount numeric; p uuid; side text; current_member uuid; depth int:=0; lim int; begin
 select buyer_id into buyer from public.orders where id=oid and payment_status='confirmed';
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=oid and a.share_kind='network_rewards';
 b:=trunc(funding/300,4); if b<=0 then return; end if;
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(oid,buyer,funding,b,trunc(b*0.35,4)) on conflict do nothing;
 if not found then return; end if;
 insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
 select buyer,k,case when k in('BV','DP') then b else trunc(b/2,4) end,oid,'credit','shopping:'||oid||':'||k from unnest(array['BV','DP','GP','BRP']) k where case when k in('BV','DP') then b else trunc(b/2,4) end>0;
 select coalesce(sum(nominal),0) into total from private.sale_reward_candidates(buyer,b);
 scale:=case when total>0 then least(1,trunc(b*0.55,4)/total) else 0 end;
 for r in select * from private.sale_reward_candidates(buyer,b) order by depth loop
  amount:=trunc(r.nominal*scale,4); perform private.post_shopping_bonus(oid,r.beneficiary,r.method,r.depth,b,r.nominal,amount);paid:=paid+amount;
 end loop;
 current_member:=buyer;
 loop
  select parent_id,bp.side into p,side from public.binary_placements bp where bp.member_id=current_member;
  exit when p is null; depth:=depth+1;
  if depth>100 then raise exception 'Binary ancestry exceeds limit'; end if;
  if trunc(b/2,4)>0 then insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(b/2,4),side,oid,'credit','shopping-bp:'||oid||':'||p); end if;
  lim:=case private.current_package_code(p) when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 when 'PREMIUM' then 30 else 0 end;
  if depth<=lim and exists(select 1 from public.member_profiles where user_id=p and status='active') then
   amount:=trunc(b*depth/300,4)-trunc(b*(depth-1)/300,4);
   perform private.post_shopping_bonus(oid,p,'single_line',depth,b,b/300,amount); single_paid:=single_paid+amount;
  end if;
  current_member:=p;
 end loop;
 update public.shopping_reward_events set direct_generation_mio=paid,single_line_mio=single_paid where order_id=oid;
end $$;

-- Preserve the old implementation for immutable legacy snapshots.
alter function private.post_vendor_sale() rename to post_vendor_sale_legacy;
create function private.post_vendor_sale() returns trigger language plpgsql security definer set search_path='' as $$
declare i public.order_items%rowtype; cumul numeric; previous numeric; k text; amount numeric; beneficiary uuid; state text; rate numeric; begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  for i in select * from public.order_items where order_id=new.id loop
   if i.distribution_basis<>'sale_v2' then raise exception 'Legacy unpaid order requires explicit reconciliation'; end if;
   insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr) values(i.vendor_id,i.id,i.line_total_pkr,i.commission_pool_pkr,i.line_total_pkr-i.commission_pool_pkr) on conflict(order_item_id) do nothing;
   cumul:=0;previous:=0;
   foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'] loop
    rate:=(i.commission_split_snapshot->>k)::numeric;cumul:=cumul+rate;
    amount:=case k when 'company' then round(i.line_total_pkr*0.05,2) when 'buyer_discount' then i.buyer_discount_pkr else greatest(0,least(i.commission_pool_pkr-previous,round(i.line_total_pkr*cumul/100,2)-previous)) end; previous:=previous+amount;
    beneficiary:=case k when 'buyer_discount' then new.buyer_id when 'company' then (select company_id from private.network_foundation limit 1) when 'affiliate' then i.affiliate_id_snapshot when 'sponsor' then i.sponsor_id_snapshot when 'second_upline' then i.second_upline_id_snapshot when 'introducer' then i.introducer_id_snapshot end;
    state:=case when k='buyer_discount' then 'discount_applied' when k='network_rewards' then 'reserved' when beneficiary is null then 'held' else 'earned' end;
    if amount>0 then insert into public.commission_allocations(order_item_id,share_kind,beneficiary_id,amount_pkr,status) values(i.id,k,beneficiary,amount,state) on conflict(order_item_id,share_kind) do nothing; end if;
   end loop;
   if previous<>i.commission_pool_pkr then raise exception 'Sale allocation does not reconcile'; end if;
  end loop;
  perform private.post_shopping_rewards(new.id);
 end if; return new;
end $$;
drop trigger post_vendor_sale on public.orders;
create trigger post_vendor_sale after update of payment_status on public.orders for each row execute function private.post_vendor_sale();

-- Shopping activations grant package eligibility, not a second funded event.
do $$ declare f text; name text; begin
 foreach name in array array['private.credit_activation_bonuses(uuid)','private.credit_single_line(uuid)','private.credit_binary_volume(uuid)'] loop
  f:=pg_get_functiondef(name::regprocedure);
  if name like '%credit_activation_bonuses%' then f:=replace(f,'if act.id is null or act.status<>''approved'' then return 0; end if;','if act.id is null or act.status<>''approved'' or act.source=''SHOPPING_PPV'' then return 0; end if;');
  elsif name like '%credit_single_line%' then f:=replace(f,'if a.id is null then return; end if;','if a.id is null or a.source=''SHOPPING_PPV'' then return; end if;');
  else f:=replace(f,'if act.id is null or act.bp<=0 then return 0; end if;','if act.id is null or act.bp<=0 or act.source=''SHOPPING_PPV'' then return 0; end if;'); end if;
  execute f;
 end loop;
 f:=pg_get_functiondef('private.assign_activation_points()'::regprocedure);
 execute replace(f,'if new.status=''approved'' then','if new.status=''approved'' and new.source<>''SHOPPING_PPV'' then');
 f:=pg_get_functiondef('private.activate_next_ppv_package(uuid,uuid,numeric)'::regprocedure);
 f:=replace(f,'    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)'||chr(10)||'      values(p_member_id,''PPV'',p.ppv,aid,''credit'',id_key || '':ppv'');','    -- Activation never mints additional shopping PPV.');
 f:=replace(f,'    p_cumulative_ppv := p_cumulative_ppv+p.ppv;','    -- No synthetic PPV increase.');execute f;
end $$;

-- Bound new paid-package direct+generation to the 55% remaining after binary35/SL10.
do $$ declare f text; begin
 f:=pg_get_functiondef('private.credit_activation_bonuses(uuid)'::regprocedure);
 f:=replace(f,'  stack_gen1 boolean := false;','  stack_gen1 boolean := false;'||chr(10)||'  candidate_total numeric; funding_scale numeric:=1;');
 f:=replace(f,'  if direct_sponsor is not null and exists',
 '  select coalesce(sum(nominal),0) into candidate_total from private.sale_reward_candidates(act.member_id,act.bv);'||chr(10)||
 '  if stack_gen1 then candidate_total:=candidate_total+act.bv*0.30; end if;'||chr(10)||
 '  funding_scale:=case when candidate_total>0 then least(1,trunc(least(act.bv,act.base_value,act.payable_price-act.company_fee)*0.55,4)/candidate_total) else 1 end;'||chr(10)||
 '  if direct_sponsor is not null and exists');
 f:=replace(f,'payout := round(act.bv*act.direct_rate,4);','payout := trunc(act.bv*act.direct_rate*funding_scale,4);');
 f:=replace(f,'payout := round(act.bv*rate,4);','payout := trunc(act.bv*rate*funding_scale,4);');
 f:=replace(f,'''phase1-direct-v1''','''funded-direct-v2''');f:=replace(f,'''phase1-generation-v1''','''funded-generation-v2''');
 f:=replace(f,'''source_package'',act.package_code','''funding_scale'',funding_scale,''direct_generation_cap'',0.55,''source_package'',act.package_code');execute f;
end $$;

-- Weekly pool consumes actual paid shopping events, not PPV activation package values.
do $$ declare f text; begin
 f:=pg_get_functiondef('public.admin_close_binary_cycle(text,timestamptz,timestamptz,text)'::regprocedure);
 f:=replace(f,'where status=''approved'' and activated_at>=p_starts_at and activated_at<p_ends_at;',
 'where status=''approved'' and source<>''SHOPPING_PPV'' and activated_at>=p_starts_at and activated_at<p_ends_at;');
 f:=replace(f,'sum(base_value)','sum(least(base_value,bv,payable_price-company_fee))');
 f:=replace(f,' pool:=round(eligible*0.35,4);',
 ' pool:=trunc(eligible*0.35,4)+(select coalesce(sum(binary_reserve_mio),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);'||chr(10)||
 '  eligible:=eligible+(select coalesce(sum(bv),0) from public.shopping_reward_events where created_at>=p_starts_at and created_at<p_ends_at);');
 f:=replace(f,'from public.point_ledger pl join public.package_activations a on a.id=pl.source_activation_id',
 'from public.point_ledger pl left join public.package_activations a on a.id=pl.source_activation_id left join public.shopping_reward_events s on s.order_id=pl.source_order_id');
 f:=replace(f,'where pl.point_type=''BP'' and a.status=''approved'' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at',
 'where pl.point_type=''BP'' and ((a.status=''approved'' and a.source<>''SHOPPING_PPV'' and a.activated_at>=p_starts_at and a.activated_at<p_ends_at) or (s.created_at>=p_starts_at and s.created_at<p_ends_at))');
 f:=replace(f,'where pl.point_type=''BP'' and a.status=''approved'' and a.activated_at<p_ends_at and pl.created_at<=now()',
 'where pl.point_type=''BP'' and ((a.status=''approved'' and a.source<>''SHOPPING_PPV'' and a.activated_at<p_ends_at) or s.created_at<p_ends_at) and pl.created_at<=now()');
 execute f;
end $$;

-- A locked source event enforces caps even if later rates change unexpectedly.
create function private.guard_bonus_funding() returns trigger language plpgsql security definer set search_path='' as $$
declare b numeric; spent numeric; ceiling numeric; begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new; end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid'; end if;
 if new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status='posted';
 else
  if new.source_order_id is not null then select bv into b from public.shopping_reward_events where order_id=new.source_order_id for update;
  else select least(bv,base_value,payable_price-company_fee) into b from public.package_activations where id=new.source_activation_id and status='approved' and source<>'SHOPPING_PPV' for update; end if;
  ceiling:=trunc(b*case when new.method='single_line' then 0.10 else 0.55 end,4);
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where status='posted' and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id)) and case when new.method='single_line' then method='single_line' else method in('direct','generation') end;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling then raise exception 'Bonus would exceed its funded source budget'; end if;return new;
end $$;
create trigger guard_bonus_funding before insert on public.bonus_transactions for each row execute function private.guard_bonus_funding();
revoke all on function private.guard_bonus_funding() from public,anon,authenticated;
do $$ declare f text; name text; begin
 foreach name in array array['public.resolve_commission_recipient(uuid,text,text)','public.record_commission_payment(uuid,text)'] loop
  f:=pg_get_functiondef(name::regprocedure);
  f:=replace(f,'''company'',''buyer_discount''','''company'',''buyer_discount'',''network_rewards'',''unallocated''');
  f:=replace(f,'''buyer_discount'',''company''','''buyer_discount'',''company'',''network_rewards'',''unallocated''');execute f;
 end loop;
 f:=pg_get_functiondef('private.credit_single_line(uuid)'::regprocedure);
 f:=replace(f,'round(a.bv*r.depth/300,4)-round(a.bv*(r.depth-1)/300,4)','trunc(least(a.bv,a.base_value,a.payable_price-a.company_fee)*r.depth/300,4)-trunc(least(a.bv,a.base_value,a.payable_price-a.company_fee)*(r.depth-1)/300,4)');execute f;
end $$;

-- Allure formula remains tied to sale price on every edit. Leave approval manual.
create function private.allure_formula() returns trigger language plpgsql security definer set search_path='' as $$ begin
 if exists(select 1 from public.vendors where id=new.vendor_id and is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%') then
  new.ppv_per_unit:=case when new.price_pkr>0 then trunc(new.price_pkr*0.25/300*0.90,4) else null end;
 end if;return new;
end $$;
create trigger zz_allure_formula before insert or update on public.products for each row execute function private.allure_formula();
update public.products set price_pkr=price_pkr where vendor_id in(select id from public.vendors where is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%');
insert into public.audit_logs(action,entity_type,entity_id,after_data)
select 'ALLURE_SALE_FORMULA_SET','vendor',id,jsonb_build_object('company_sale_percent',5,'network_sale_percent',25,'pkr_per_point',300,'ppv_factor',0.90,'rounding','truncate_4','approval','manual') from public.vendors where is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%';

create function public.vendor_company_earnings() returns jsonb language plpgsql stable security definer set search_path='' as $$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 return coalesce((select jsonb_agg(r) from(select v.id,v.business_name,coalesce(sum(a.amount_pkr),0) company_earnings_pkr from public.vendors v left join public.order_items i on i.vendor_id=v.id left join public.commission_allocations a on a.order_item_id=i.id and a.share_kind='company' group by v.id,v.business_name order by v.business_name)r),'[]');
end $$;
revoke all on function public.set_vendor_sale_distribution(uuid,jsonb),public.vendor_company_earnings() from public,anon;
grant execute on function public.set_vendor_sale_distribution(uuid,jsonb),public.vendor_company_earnings() to authenticated;
revoke all on function private.valid_sale_distribution(jsonb,numeric),private.sale_reward_candidates(uuid,numeric),private.post_shopping_bonus(uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric),private.post_shopping_rewards(uuid),private.post_vendor_sale_legacy(),private.allure_formula() from public,anon,authenticated;
notify pgrst,'reload schema';
-- Shopping point conversion is fixed and independent of Premium currency quotes.
do $$ declare f text; begin
 f:=pg_get_functiondef('private.place_marketplace_order(jsonb,text,text,text,text,text)'::regprocedure);
 f:=replace(f,'  select (config_value->>''usd_to_pkr_rate'')::numeric into rate from public.system_config'||chr(10)||'    where config_key=''CURRENCY'' and effective_to is null order by version desc limit 1;'||chr(10)||'  if rate is null then raise exception ''Marketplace is waiting for the admin to configure the USD/PKR PPV conversion rate''; end if;','  rate:=300; -- Fixed shopping conversion.');execute f;
 f:=pg_get_functiondef('public.company_network_summary()'::regprocedure);
 f:=replace(f,'from public.package_activations where status=''approved''','from public.package_activations where status=''approved'' and source<>''SHOPPING_PPV''');execute f;
 f:=pg_get_functiondef('public.offer_vendor_commission(uuid,numeric,text)'::regprocedure);
 f:=replace(f,'p_rate<0 or','p_rate<0.05 or');execute f;
 f:=pg_get_functiondef('public.admin_review_vendor_application(uuid,boolean,numeric)'::regprocedure);
 f:=replace(f,'p_commission_rate<0 or','p_commission_rate<0.05 or');execute f;
end $$;
