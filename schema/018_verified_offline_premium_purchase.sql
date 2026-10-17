-- Owner-approved separate MIO purchase + Premium activation, not an ordinary transfer.
alter table public.mio_ledger drop constraint mio_ledger_action_check;
alter table public.mio_ledger add constraint mio_ledger_action_check check(action in('admin_mint','admin_burn','transfer_in','transfer_out','package_activation','bonus_credit','purchase_in','purchase_out'));
alter table public.mio_ledger drop constraint mio_ledger_check;
alter table public.mio_ledger add constraint mio_ledger_check check((action in('transfer_in','transfer_out','purchase_in','purchase_out') and counterparty_id is not null and transfer_id is not null) or (action not in('transfer_in','transfer_out','purchase_in','purchase_out') and counterparty_id is null and transfer_id is null));
alter table public.mio_ledger drop constraint mio_ledger_amount_check;
alter table public.mio_ledger add constraint mio_ledger_amount_check check((action in('admin_mint','transfer_in','bonus_credit','purchase_in') and amount>0) or (action in('admin_burn','transfer_out','package_activation','purchase_out') and amount<0));
create table public.premium_purchase_requests(
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.member_profiles(user_id),package_version integer not null,
 mio_amount numeric(20,4) not null check(mio_amount>0),usd_to_pkr_rate numeric(14,6) not null check(usd_to_pkr_rate>0),expected_pkr numeric(14,2) not null check(expected_pkr>0),
 payment_reference text not null unique,payment_details text not null,status text not null default 'pending' check(status in('pending','approved','rejected')),
 activation_id uuid references public.package_activations(id),reviewed_by uuid references auth.users(id),review_note text,created_at timestamptz not null default now(),reviewed_at timestamptz,
 idempotency_key text not null unique);
alter table public.premium_purchase_requests enable row level security;
create policy "buyer or operations reads Premium purchase" on public.premium_purchase_requests for select to authenticated using(member_id=auth.uid() or private.has_role('admin'));
grant select on public.premium_purchase_requests to authenticated;
revoke insert,update,delete on public.premium_purchase_requests from anon,authenticated;
create function public.request_offline_premium_purchase(p_reference text,p_details text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.package_versions%rowtype; rate numeric; rid uuid; begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status='active') then raise exception 'Active member account required'; end if;
 if private.has_role('admin') then raise exception 'Use your company MIO wallet to activate your own package'; end if;
 if length(trim(coalesce(p_reference,'')))<8 or length(p_reference)>200 or length(trim(coalesce(p_details,'')))<20 or length(p_details)>2000 or length(coalesce(p_idempotency_key,''))<12 then raise exception 'Enter the genuine payment provider, reference and payment details'; end if;
 perform pg_advisory_xact_lock(hashtextextended('premium-purchase:'||uid::text,0));
 select id into rid from public.premium_purchase_requests where member_id=uid and idempotency_key=uid::text||':'||p_idempotency_key;
 if rid is not null then return rid; end if;
 if private.current_package_code(uid)='PREMIUM' then raise exception 'Premium is already active'; end if;
 if exists(select 1 from public.premium_purchase_requests where member_id=uid and status='pending') then raise exception 'You already have a pending Premium purchase'; end if;
 select * into p from public.package_versions where package_code='PREMIUM' and is_active and effective_from<=now() and (effective_to is null or effective_to>now()) order by version desc limit 1;
 if p.package_code is null then raise exception 'Premium is unavailable'; end if;
 select (config_value->>'usd_to_pkr_rate')::numeric into rate from public.system_config where config_key='CURRENCY' and effective_to is null order by version desc limit 1;
 if rate is null then raise exception 'The company must configure the purchase conversion rate first'; end if;
 if not exists(select 1 from public.system_config where config_key='OFFLINE_PAYMENT' and effective_to is null and length(config_value->>'instructions')>=20) then raise exception 'Company payment instructions are not configured'; end if;
 insert into public.premium_purchase_requests(member_id,package_version,mio_amount,usd_to_pkr_rate,expected_pkr,payment_reference,payment_details,idempotency_key)
 values(uid,p.version,p.payable_price,rate,round(p.payable_price*rate,2),upper(trim(p_reference)),trim(p_details),uid::text||':'||p_idempotency_key) returning id into rid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(uid,'OFFLINE_PREMIUM_REQUESTED','premium_purchase',rid);
 return rid;
end $$;
create function public.review_offline_premium_purchase(p_request_id uuid,p_approve boolean,p_verified_pkr numeric,p_note text)
returns uuid language plpgsql security definer set search_path='' as $$
declare owner uuid:=auth.uid(); r public.premium_purchase_requests%rowtype; p public.package_versions%rowtype; aid uuid:=gen_random_uuid(); lock_uid uuid; request_key text; new_balance numeric;
begin
 if owner is null or not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 perform private.require_recent_totp();
 if p_approve is null or length(trim(coalesce(p_note,'')))<20 or length(p_note)>2000 then raise exception 'Record a verification or rejection note of at least 20 characters'; end if;
 select * into r from public.premium_purchase_requests where id=p_request_id for update;
 if r.id is null then raise exception 'Purchase request not found'; end if;
 if r.status='approved' then return r.activation_id; end if;
 if r.status<>'pending' then raise exception 'Purchase request is already closed'; end if;
 if not p_approve then
  update public.premium_purchase_requests set status='rejected',reviewed_by=owner,review_note=trim(p_note),reviewed_at=now() where id=r.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(owner,'OFFLINE_PREMIUM_REJECTED','premium_purchase',r.id,jsonb_build_object('note',trim(p_note)));
  return null;
 end if;
 if p_verified_pkr is null or p_verified_pkr<>r.expected_pkr then raise exception 'Verified payment must match the saved purchase amount'; end if;
 if r.member_id=owner or not exists(select 1 from public.member_profiles where user_id=r.member_id and status='active') then raise exception 'Active buyer account required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('package-member:'||r.member_id::text,0));
 if private.current_package_code(r.member_id)='PREMIUM' then raise exception 'Premium is already active; resolve the duplicate payment with the buyer'; end if;
 select * into p from public.package_versions where package_code='PREMIUM' and version=r.package_version;
 if p.package_code is null or p.payable_price<>r.mio_amount then raise exception 'Saved package configuration not found'; end if;
 for lock_uid in select member_id from public.mio_wallet_accounts where member_id in(owner,r.member_id) order by member_id for update loop null; end loop;
 update public.mio_wallet_accounts set balance=balance-r.mio_amount,updated_at=now() where member_id=owner and balance>=r.mio_amount returning balance into new_balance;
 if new_balance is null then raise exception 'Company wallet needs sufficient MIO stock before approval'; end if;
 request_key:='offline-premium:'||r.id::text;
 update public.mio_wallet_accounts set balance=balance+r.mio_amount,updated_at=now() where member_id=r.member_id;
 insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,reason,idempotency_key) values
 (owner,-r.mio_amount,'purchase_out',r.member_id,r.id,'Verified Premium purchase',request_key||':stock'),
 (r.member_id,r.mio_amount,'purchase_in',owner,r.id,'Verified Premium purchase',request_key||':purchase');
 update public.mio_wallet_accounts set balance=balance-r.mio_amount,updated_at=now() where member_id=r.member_id;
 insert into public.package_activations(id,member_id,package_code,package_version,source,source_reference,payment_currency,payment_amount,usd_to_payment_rate,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key)
 values(aid,r.member_id,p.package_code,p.version,'MIO_POINTS',r.id::text,'MIO',r.mio_amount,1,p.base_value,p.company_fee,p.payable_price,p.ppv,p.bv,p.dp,p.gp,p.bp,p.brp,p.direct_rate,p.generation1_rate,p.binary_entitlement,'approved',now(),owner,request_key);
 insert into public.mio_ledger(member_id,amount,action,activation_id,reason,idempotency_key) values(r.member_id,-r.mio_amount,'package_activation',aid,'Offline purchase activated atomically',request_key||':activation');
 insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key) values(r.member_id,'PPV',p.ppv,aid,'credit',request_key||':ppv');
 perform private.credit_activation_bonuses(aid);
 update public.premium_purchase_requests set status='approved',activation_id=aid,reviewed_by=owner,review_note=trim(p_note),reviewed_at=now() where id=r.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(owner,'OFFLINE_PREMIUM_APPROVED','premium_purchase',r.id,jsonb_build_object('buyer_id',r.member_id,'activation_id',aid,'mio',r.mio_amount,'verified_pkr',p_verified_pkr,'conversion_rate',r.usd_to_pkr_rate,'note',trim(p_note)));
 return aid;
end $$;
revoke all on function public.request_offline_premium_purchase(text,text,text),public.review_offline_premium_purchase(uuid,boolean,numeric,text) from public,anon;
grant execute on function public.request_offline_premium_purchase(text,text,text),public.review_offline_premium_purchase(uuid,boolean,numeric,text) to authenticated;
insert into public.system_config(config_key,version,config_value,effective_from) values('OFFLINE_PAYMENT',1,'{"instructions":null}',now());
create function public.set_offline_payment_instructions(p_instructions text) returns void language plpgsql security definer set search_path='' as $$
declare ver integer; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if length(trim(coalesce(p_instructions,'')))<20 or length(p_instructions)>4000 then raise exception 'Provide payment instructions of 20–4000 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-payment-config',0));
 select coalesce(max(version),0)+1 into ver from public.system_config where config_key='OFFLINE_PAYMENT';
 update public.system_config set effective_to=now() where config_key='OFFLINE_PAYMENT' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('OFFLINE_PAYMENT',ver,jsonb_build_object('instructions',trim(p_instructions)),now(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'OFFLINE_PAYMENT_INSTRUCTIONS_SET','system_config',jsonb_build_object('version',ver));
end $$;
revoke all on function public.set_offline_payment_instructions(text) from public,anon;
grant execute on function public.set_offline_payment_instructions(text) to authenticated;
