-- Future orders only: inactive members may refer and sell, but earnings remain reserved.
alter table public.bonus_transactions add column held_ppv numeric(18,4) not null default 0;
alter table public.bonus_transactions add column held_bv numeric(18,4) not null default 0;
alter table public.commission_allocations add column held_ppv numeric(18,4) not null default 0;
alter table public.commission_allocations add column held_bv numeric(18,4) not null default 0;
create table public.reward_point_credits(id uuid primary key default gen_random_uuid(),member_id uuid not null references public.member_profiles(user_id),bonus_id uuid unique references public.bonus_transactions(id),allocation_id uuid unique references public.commission_allocations(id),ppv numeric(18,4) not null check(ppv>=0),bv numeric(18,4) not null check(bv>=0),created_at timestamptz not null default now(),check(num_nonnulls(bonus_id,allocation_id)=1));
alter table public.reward_point_credits enable row level security;
create policy reward_points_read on public.reward_point_credits for select to authenticated using(member_id=auth.uid() or private.has_role('admin'));
revoke all on public.reward_point_credits from public,anon,authenticated;
grant select on public.reward_point_credits to authenticated;
create function private.registered_member(member uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.member_profiles where user_id=member and status in('active','inactive') and terms_accepted_at is not null)$$;
create or replace function private.enforce_package_membership() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.sponsor_id is not null and (TG_OP='INSERT' or new.sponsor_id is distinct from old.sponsor_id) and not private.registered_member(new.sponsor_id) and not exists(select 1 from public.user_roles where user_id=new.sponsor_id and role='admin') then raise exception 'Registered sponsor required';end if;
 if new.status='active' and not exists(select 1 from public.user_roles where user_id=new.user_id and role='admin') and not exists(select 1 from public.package_activations where member_id=new.user_id and status='approved') then new.status:='inactive';end if;return new;
end $$;
do $$declare f text; sig text;begin
 foreach sig in array array['private.create_member_profile()','private.complete_referral_join(text,text,text,boolean)','public.lookup_side_referral(text)'] loop
  f:=pg_get_functiondef(sig::regprocedure);f:=replace(f,'and status=''active''','and status in (''active'',''inactive'') and terms_accepted_at is not null');f:=replace(f,'and m.status=''active''','and m.status in (''active'',''inactive'') and m.terms_accepted_at is not null');execute f;
 end loop;
 f:=pg_get_functiondef('private.snapshot_commission()'::regprocedure);f:=replace(f,'where status=''active'' and','where status in (''active'',''inactive'') and terms_accepted_at is not null and');execute f;
 f:=pg_get_functiondef('private.guard_bonus_funding()'::regprocedure);f:=replace(f,'status=''posted''','status in (''posted'',''pending'')');execute f;
end $$;
create or replace function private.sale_reward_candidates(member uuid,bv numeric) returns table(beneficiary uuid,method public.bonus_method,depth integer,nominal numeric) language sql stable security definer set search_path='' as $$
 with recursive up(id,sponsor,depth,path) as(select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor where u.depth<10 and not m.user_id=any(u.path))
 select u.id,case when u.depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,u.depth,
 bv*case when u.depth=1 then coalesce((select direct_rate from public.package_versions where package_code=case when private.package_eligible(u.id) then coalesce(private.current_package_code(member),'BASIC_1') else 'BASIC_1' end and is_active order by version desc limit 1),0.20) else 0.05 end
 from up u where u.depth>0 and private.registered_member(u.id) and (u.depth=1 or (private.package_eligible(u.id) and u.depth<=coalesce((select pv.max_generations from public.package_activations a join public.package_versions pv on pv.package_code=a.package_code and pv.version=a.package_version where a.member_id=u.id and a.status='approved' order by a.activated_at desc limit 1),0)));
$$;
create or replace function private.enforce_bonus_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.payable_amount<=0 or new.status='reversed' then return new;end if;
 if new.source_order_id is not null then select buyer_id into buyer from public.orders where id=new.source_order_id;elsif new.source_activation_id is not null then select member_id into buyer from public.package_activations where id=new.source_activation_id;end if;
 if buyer=new.beneficiary_id then raise exception 'Own purchase gives PPV only';end if;
 if not private.package_eligible(new.beneficiary_id) then
  if new.method<>'direct' or not private.registered_member(new.beneficiary_id) or coalesce(new.generation,1)<>1 then raise exception 'Inactive member can earn held first-level direct only';end if;
  new.status:='pending';new.held_bv:=trunc(new.payable_amount,4);new.held_ppv:=trunc(new.payable_amount*0.90,4);
 end if;return new;
end $$;
-- The earlier eligibility trigger already runs before the funding guard.
create or replace function private.enforce_commission_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.share_kind in('affiliate','sponsor','second_upline','introducer') and new.beneficiary_id is not null then
  select o.buyer_id into buyer from public.order_items i join public.orders o on o.id=i.order_id where i.id=new.order_item_id;
  if new.beneficiary_id=buyer then raise exception 'Self affiliate commission is not allowed';end if;
  if not private.package_eligible(new.beneficiary_id) then
   if new.status='paid' then raise exception 'Activate a package before withdrawal';end if;
   if new.share_kind='affiliate' and private.registered_member(new.beneficiary_id) then
    new.status:='held';new.held_bv:=trunc(new.amount_pkr/300,4);new.held_ppv:=trunc(new.held_bv*0.90,4);
   else new.beneficiary_id:=null;new.status:='held';end if;
  elsif new.share_kind='affiliate' and TG_OP='INSERT' then new.held_bv:=trunc(new.amount_pkr/300,4);new.held_ppv:=trunc(new.held_bv*0.90,4);
  end if;
 end if;return new;
end $$;
-- Posting a reserved direct amount must not credit the spendable wallet yet.
do $$declare f text;begin
 f:=pg_get_functiondef('private.post_shopping_bonus(uuid,uuid,public.bonus_method,integer,numeric,numeric,numeric)'::regprocedure);
 f:=replace(f,'if tx is not null then','if tx is not null and private.package_eligible(beneficiary) then');execute f;
 f:=pg_get_functiondef('private.credit_activation_bonuses(uuid)'::regprocedure);
 f:=replace(f,'if direct_sponsor is not null and exists(select 1 from public.member_profiles where user_id=direct_sponsor and status=''active'')'||chr(10)||'     and private.current_package_code(direct_sponsor) is not null then','if direct_sponsor is not null and private.registered_member(direct_sponsor) then');
 f:=replace(f,'payout := trunc(act.bv*act.direct_rate*funding_scale,4);','payout := trunc(act.bv*(case when private.package_eligible(direct_sponsor) then act.direct_rate else (select direct_rate from public.package_versions where package_code=''BASIC_1'' and is_active order by version desc limit 1) end)*funding_scale,4);');
 f:=regexp_replace(f,'if txn_id is not null then','if txn_id is not null and private.package_eligible(direct_sponsor) then');execute f;
end $$;
create function private.release_member_holds(member uuid) returns void language plpgsql security definer set search_path='' as $$declare b record;c record;begin
 perform pg_advisory_xact_lock(hashtextextended('release-member-holds:'||member::text,0));
 if not private.package_eligible(member) then return;end if;
 for b in update public.bonus_transactions set status='posted' where beneficiary_id=member and status='pending' and method='direct' returning * loop
  insert into public.mio_ledger(member_id,amount,action,source_order_id,activation_id,bonus_transaction_id,reason,idempotency_key) values(member,b.payable_amount,'bonus_credit',b.source_order_id,b.source_activation_id,b.id,'Released first-level incentive after package activation','bonus:'||b.id) on conflict(idempotency_key) do nothing;
  if found then update public.mio_wallet_accounts set balance=balance+b.payable_amount,updated_at=now() where member_id=member;end if;
  insert into public.reward_point_credits(member_id,bonus_id,ppv,bv) values(member,b.id,b.held_ppv,b.held_bv) on conflict(bonus_id) do nothing;
 end loop;
 for c in update public.commission_allocations set status='earned' where beneficiary_id=member and share_kind='affiliate' and status='held' returning * loop
  insert into public.reward_point_credits(member_id,allocation_id,ppv,bv) values(member,c.id,c.held_ppv,c.held_bv) on conflict(allocation_id) do nothing;
 end loop;
end $$;
create function private.release_on_activation() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' then perform private.release_member_holds(new.member_id);end if;return new;
end $$;
create trigger ab_release_member_holds after insert or update of status on public.package_activations for each row execute function private.release_on_activation();
create function private.credit_active_affiliate_points() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.share_kind='affiliate' and new.status='earned' and private.package_eligible(new.beneficiary_id) then insert into public.reward_point_credits(member_id,allocation_id,ppv,bv) values(new.beneficiary_id,new.id,new.held_ppv,new.held_bv) on conflict(allocation_id) do nothing;end if;return new;
end $$;
create trigger affiliate_reward_points after insert or update on public.commission_allocations for each row execute function private.credit_active_affiliate_points();
create function public.my_reward_holds() returns jsonb language plpgsql security definer set search_path='' as $$declare uid uuid:=auth.uid();begin
 if uid is null then raise exception 'Sign in required';end if;
 return jsonb_build_object('direct_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=uid and status='pending'),0),'affiliate_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where beneficiary_id=uid and share_kind='affiliate' and status='held'),0),'held_ppv',coalesce((select sum(held_ppv) from public.bonus_transactions where beneficiary_id=uid and status='pending'),0)+coalesce((select sum(held_ppv) from public.commission_allocations where beneficiary_id=uid and status='held'),0),'held_bv',coalesce((select sum(held_bv) from public.bonus_transactions where beneficiary_id=uid and status='pending'),0)+coalesce((select sum(held_bv) from public.commission_allocations where beneficiary_id=uid and status='held'),0),'released_ppv',coalesce((select sum(ppv) from public.reward_point_credits where member_id=uid),0),'released_bv',coalesce((select sum(bv) from public.reward_point_credits where member_id=uid),0),'withdrawal_unlocked',private.package_eligible(uid));end $$;
revoke all on function private.registered_member(uuid),private.release_member_holds(uuid),private.release_on_activation(),private.credit_active_affiliate_points() from public,anon,authenticated;
revoke all on function public.my_reward_holds() from public,anon;
grant execute on function public.my_reward_holds() to authenticated;
notify pgrst,'reload schema';
