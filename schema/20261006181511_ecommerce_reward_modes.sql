-- New orders choose one funded rewards route. Existing orders retain their snapshot.
alter table public.member_profiles add column shopping_reward_mode text not null default 'PPV' check(shopping_reward_mode in('PPV','MIO'));
alter table public.member_profiles add column achieved_rank text check(achieved_rank in('leader','team_manager','team_leader','senior_team_leader'));
alter table public.orders add column reward_version integer not null default 1;
alter table public.orders alter column reward_version set default 2;
alter table public.orders add column reward_mode text not null default 'PPV' check(reward_mode in('PPV','MIO'));
alter table public.orders add column reward_owner_id uuid references public.member_profiles(user_id);
alter table public.orders add column selling_affiliate_id uuid references public.member_profiles(user_id);
alter table public.orders add column reward_sponsor_id uuid references public.member_profiles(user_id);
alter table public.orders add column reward_second_sponsor_id uuid references public.member_profiles(user_id);
alter table public.orders add column reward_ppv_total numeric(18,4) not null default 0;
create function public.set_shopping_reward_mode(p_mode text) returns void language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or not private.package_eligible(auth.uid()) then raise exception 'Activate any package to choose MIO rewards';end if;
 if p_mode is null or p_mode not in('PPV','MIO') then raise exception 'Choose PPV or MIO';end if;
 update public.member_profiles set shopping_reward_mode=p_mode where user_id=auth.uid();
end $$;
create function private.snapshot_order_reward_mode() returns trigger language plpgsql security definer set search_path='' as $$declare code text:=upper(trim(coalesce(current_setting('mio.affiliate_code',true),'')));seller uuid;begin
 if code<>'' then
 select user_id into seller from public.member_profiles where (upper(member_code)=code or upper(replace(member_code,'MIO-',''))=code or upper(referral_code)=regexp_replace(code,'-[LR]$','')) and status in('active','inactive') and terms_accepted_at is not null;
 if seller is null then raise exception 'Selling link is no longer valid';end if;
 end if;
 if seller=new.buyer_id then seller:=null;end if;
 new.selling_affiliate_id:=seller;new.reward_owner_id:=coalesce(seller,new.buyer_id);
 select case when private.package_eligible(user_id) then shopping_reward_mode else 'PPV' end,sponsor_id into new.reward_mode,new.reward_sponsor_id from public.member_profiles where user_id=new.reward_owner_id;
 select sponsor_id into new.reward_second_sponsor_id from public.member_profiles where user_id=new.reward_sponsor_id;
 new.reward_mode:=coalesce(new.reward_mode,'PPV');return new;
end $$;
create trigger snapshot_order_reward_mode before insert on public.orders for each row execute function private.snapshot_order_reward_mode();
-- Keep the agreed commission and PPV calculation, and save vendor attribution.
do $$declare f text;begin f:=pg_get_functiondef('private.snapshot_commission()'::regprocedure);f:=replace(f,'new.buyer_discount_pkr:=0;return new;','new.buyer_discount_pkr:=0;new.introducer_id_snapshot:=v.introduced_by;return new;');execute f;end $$;
create table public.ecommerce_rewards(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders(id),order_item_id uuid not null references public.order_items(id),
 beneficiary_id uuid references public.member_profiles(user_id),reward_kind text not null check(reward_kind in('cashback','affiliate','sponsor','second_sponsor','vendor_introducer')),
 rate numeric not null,base_points numeric(18,4) not null,amount numeric(18,4) not null check(amount>=0),
 status text not null default 'pending_delivery' check(status in('pending_delivery','held_activation','posted','company_leftover','cancelled')),
 created_at timestamptz not null default now(),credited_at timestamptz,unique(order_item_id,reward_kind));
create index ecommerce_rewards_beneficiary on public.ecommerce_rewards(beneficiary_id,status);
alter table public.ecommerce_rewards enable row level security;
revoke all on public.ecommerce_rewards from public,anon,authenticated;grant select on public.ecommerce_rewards to authenticated;
create policy ecommerce_read on public.ecommerce_rewards for select to authenticated using(beneficiary_id=auth.uid() or private.has_role('admin'));
create function private.prepare_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;b numeric;prev numeric:=0;cum numeric:=0;r record;amt numeric;begin
 select * into o from public.orders where id=new.order_id;
 if o.reward_version<>2 then return new;end if;
 b:=trunc(new.ppv_per_unit_snapshot*new.quantity,4);
 update public.orders set reward_ppv_total=reward_ppv_total+b where id=o.id;
 if o.reward_mode='MIO' and b>0 then
 for r in select * from (values
 (1,case when o.selling_affiliate_id is null then 'cashback' else 'affiliate' end,o.reward_owner_id,.65::numeric),
 (2,'sponsor',o.reward_sponsor_id,.15::numeric),(3,'second_sponsor',o.reward_second_sponsor_id,.075::numeric),(4,'vendor_introducer',new.introducer_id_snapshot,.125::numeric)) x(seq,kind,who,rate) order by seq loop
 cum:=cum+r.rate;amt:=trunc(b*cum,4)-prev;prev:=prev+amt;
 insert into public.ecommerce_rewards(order_id,order_item_id,beneficiary_id,reward_kind,rate,base_points,amount) values(o.id,new.id,r.who,r.kind,r.rate,b,amt);
 end loop;end if;return new;
end $$;
create trigger prepare_order_rewards after insert on public.order_items for each row execute function private.prepare_order_rewards();
create function private.credit_ecommerce_reward(rid uuid) returns void language plpgsql security definer set search_path='' as $$declare r public.ecommerce_rewards%rowtype;begin
 select * into r from public.ecommerce_rewards where id=rid for update;
 if r.status not in('pending_delivery','held_activation') then return;end if;
 if not exists(select 1 from public.orders where id=r.order_id and status='delivered' and payment_status='confirmed') then return;end if;
 if r.beneficiary_id is null then update public.ecommerce_rewards set status='company_leftover' where id=rid;return;end if;
 if not private.package_eligible(r.beneficiary_id) then update public.ecommerce_rewards set status='held_activation' where id=rid;return;end if;
 if r.amount>0 then
 insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key) values(r.beneficiary_id,r.amount,'bonus_credit',r.order_id,'E-commerce '||r.reward_kind,'ecommerce:'||r.id) on conflict(idempotency_key) do nothing;
 if found then update public.mio_wallet_accounts set balance=balance+r.amount,updated_at=now() where member_id=r.beneficiary_id;if not found then raise exception 'Recipient wallet missing';end if;end if;
 end if;
 update public.ecommerce_rewards set status='posted',credited_at=now() where id=rid;
end $$;
create function private.release_ecommerce_holds() returns trigger language plpgsql security definer set search_path='' as $$declare r record;begin
 if new.status='approved' and private.package_eligible(new.member_id) then for r in select id from public.ecommerce_rewards where beneficiary_id=new.member_id and status='held_activation' order by id loop perform private.credit_ecommerce_reward(r.id);end loop;end if;return new;
end $$;
create trigger ac_release_ecommerce_holds after insert or update of status on public.package_activations for each row execute function private.release_ecommerce_holds();
-- Version 1 remains unchanged. Version 2 personal PPV follows the seller on attributed sales.
create or replace function private.post_shopping_rewards(oid uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.orders where id=oid and reward_version=1 and status='delivered' and payment_status='confirmed') then perform private.post_shopping_rewards_delivered(oid);end if;
end $$;
create or replace function private.release_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$declare o public.orders%rowtype;ppv numeric;total numeric;funding numeric;r record;outcome jsonb;begin
 select * into o from public.orders where id=new.id for update;
 if o.status in('cancelled','returned') and o.rewards_credited_at is null then update public.ecommerce_rewards set status='cancelled' where order_id=o.id and status='pending_delivery';return new;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' or o.rewards_credited_at is not null then return new;end if;
 select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0) into ppv from public.order_items where order_id=o.id;
 if o.reward_version=1 then o.reward_owner_id:=o.buyer_id;perform private.post_shopping_rewards(o.id);
 else
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards';
 if ppv*300>funding then raise exception 'Order rewards exceed verified funding';end if;
 if o.reward_mode='MIO' then
 for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop perform private.credit_ecommerce_reward(r.id);end loop;
 update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;perform private.sync_company_treasury();return new;
 elsif ppv>0 then
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(o.id,o.reward_owner_id,funding,ppv,trunc(ppv*.35,4)) on conflict do nothing;
 if found then outcome:=private.distribute_mlm_event(o.reward_owner_id,ppv,o.id,null,o.rules_snapshot);
 update public.shopping_reward_events set direct_generation_mio=(outcome->>'direct_generation')::numeric,single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;end if;
 end if;end if;
 if ppv>0 then insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv') on conflict(idempotency_key) do nothing;end if;
 update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;
 select coalesce(sum(amount),0) into total from public.point_ledger where member_id=o.reward_owner_id and point_type='PPV';
 perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);perform private.sync_company_treasury();return new;
end $$;
alter function private.company_treasury_sources() rename to company_treasury_sources_before_ecommerce;
create function private.company_treasury_sources() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql stable security definer set search_path='' as $$
 select * from private.company_treasury_sources_before_ecommerce()
 union all select 'ecommerce',id,'ecommerce_missing_recipient','MIO',amount from public.ecommerce_rewards where status='company_leftover'
 union all select 'order',o.id,'ecommerce_conversion_leftover','PKR',greatest(0,(select coalesce(sum(a.amount_pkr),0) from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards')-o.reward_ppv_total*300) from public.orders o where o.reward_version=2 and o.reward_mode='MIO' and o.rewards_credited_at is not null;
$$;
create trigger zz_ecommerce_treasury after update on public.ecommerce_rewards for each statement execute function private.company_treasury_event();
create function public.ecommerce_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$declare uid uuid:=auth.uid();adm boolean:=private.has_role('admin');begin
 if uid is null then raise exception 'Sign in first';end if;
 return jsonb_build_object('mode',(select shopping_reward_mode from public.member_profiles where user_id=uid),'eligible',private.package_eligible(uid),
 'totals',coalesce((select jsonb_agg(x) from(select reward_kind,status,sum(amount) amount from public.ecommerce_rewards where beneficiary_id=uid or adm group by 1,2)x),'[]'),
 'rows',coalesce((select jsonb_agg(x) from(select e.*,o.order_code,m.full_name,m.member_code,src.full_name source_name,src.member_code source_code,i.product_name_snapshot from public.ecommerce_rewards e join public.orders o on o.id=e.order_id join public.order_items i on i.id=e.order_item_id left join public.member_profiles m on m.user_id=e.beneficiary_id left join public.member_profiles src on src.user_id=o.reward_owner_id where e.beneficiary_id=uid or adm order by e.created_at desc,e.id limit 200)x),'[]'),
 'ppv_orders',coalesce((select jsonb_agg(x) from(select o.id,o.order_code,o.status,o.payment_status,o.reward_ppv_total,o.ppv_generated,o.rewards_credited_at,o.selling_affiliate_id from public.orders o where reward_owner_id=uid and reward_mode='PPV' order by created_at desc limit 100)x),'[]'),
 'top_earners',case when adm then coalesce((select jsonb_agg(x) from(select m.full_name,m.member_code,sum(e.amount) income from public.ecommerce_rewards e join public.member_profiles m on m.user_id=e.beneficiary_id where e.status='posted' group by m.user_id order by sum(e.amount) desc limit 10)x),'[]') else '[]'::jsonb end);
end $$;
create function public.admin_set_member_rank(p_code text,p_rank text) returns void language plpgsql security definer set search_path='' as $$declare target uuid;begin
 if not private.has_role('admin') then raise exception 'Master access required';end if;
 select user_id into target from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_code)),'^MIO-','');
 if target is null then raise exception 'Member not found';end if;
 update public.member_profiles set achieved_rank=nullif(p_rank,'') where user_id=target;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'MEMBER_RANK_SET','member',target,jsonb_build_object('rank',p_rank));
end $$;
-- Names are presentation metadata; package codes and financial history remain stable.
update public.system_config set config_value=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(config_value,'{plans,BASIC_1,display_name}','"Basic"'),'{plans,BASIC_2,display_name}','"Brown"'),'{plans,ADVANCED_1,display_name}','"Silver"'),'{plans,ADVANCED_2,display_name}','"Gold"'),'{plans,PREMIUM,display_name}','"Platinum"') where config_key='MLM_PLANS' and effective_to is null;
revoke all on function public.set_shopping_reward_mode(text),public.ecommerce_dashboard(),public.admin_set_member_rank(text,text) from public,anon;
grant execute on function public.set_shopping_reward_mode(text),public.ecommerce_dashboard(),public.admin_set_member_rank(text,text) to authenticated;
revoke all on function private.snapshot_order_reward_mode(),private.prepare_order_rewards(),private.credit_ecommerce_reward(uuid),private.release_ecommerce_holds(),private.company_treasury_sources_before_ecommerce() from public,anon,authenticated;
notify pgrst,'reload schema';

-- Preserve existing tree scope checks; vendor attribution uses the actual introducer.
do $$declare f text;begin
 f:=pg_get_functiondef('public.my_network(text,text,integer)'::regprocedure);
 f:=replace(f,'where member_code=upper(trim(p_root_code))','where member_code=''MIO-''||regexp_replace(upper(trim(p_root_code)),''^MIO-'','''')');
 f:=replace(f,'where m.sponsor_id=root','where v.introduced_by=root');
 f:=replace(f,'''commission_rate'',v.commission_rate','''commission_rate'',v.commission_rate,''node_type'',''vendor''');
 f:=replace(f,'''package'',private.current_package_code(t.id),','''package'',private.current_package_code(t.id),''rank'',m.achieved_rank,''joined_at'',m.created_at,');
 execute f;
end $$;
alter function public.my_network(text,text,integer) rename to my_network_before_vendor_root;
create function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$declare result jsonb;root uuid;parent jsonb;begin
 result:=public.my_network_before_vendor_root(p_kind,p_root_code,p_depth);
 if p_kind='vendor' then
 root:=auth.uid();if nullif(trim(p_root_code),'') is not null then select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');end if;
 select jsonb_build_object('id',user_id,'parent_id',null,'full_name',full_name,'member_code',member_code,'depth',0,'package',private.current_package_code(user_id),'rank',achieved_rank,'status',status) into parent from public.member_profiles where user_id=root;
 result:=jsonb_set(result,'{nodes}',jsonb_build_array(parent)||coalesce(result->'nodes','[]'::jsonb));
 end if;return result;
end $$;
revoke all on function public.my_network_before_vendor_root(text,text,integer) from public,anon,authenticated;
revoke all on function public.my_network(text,text,integer) from public,anon;grant execute on function public.my_network(text,text,integer) to authenticated;
-- Free registered members may introduce vendors; explicit vendor links are validated.
do $$declare f text;begin
 f:=pg_get_functiondef('public.submit_vendor_application(text,text,text,text,text,numeric,text)'::regprocedure);
 f:=replace(f,'if m.status<>''active'' and not consumer then','if m.terms_accepted_at is null then');
 f:=replace(f,'intro:=m.sponsor_id;','intro:=m.sponsor_id; if nullif(trim(p_introducer_code),'''') is not null then select user_id into intro from public.member_profiles where user_id<>auth.uid() and status in(''active'',''inactive'') and terms_accepted_at is not null and (member_code=''MIO-''||regexp_replace(upper(trim(p_introducer_code)),''^MIO-'','''') or referral_code=regexp_replace(upper(trim(p_introducer_code)),''-[LR]$'',''''));if intro is null then raise exception ''Invalid vendor invitation'';end if;end if;');execute f;
end $$;
update public.package_versions set display_name=case package_code when 'BASIC_1' then 'Basic' when 'BASIC_2' then 'Brown' when 'ADVANCED_1' then 'Silver' when 'ADVANCED_2' then 'Gold' when 'PREMIUM' then 'Platinum' else display_name end;

alter function public.company_master_dashboard() rename to company_master_dashboard_before_ecommerce;
create function public.company_master_dashboard() returns jsonb language plpgsql security definer set search_path='' as $$declare result jsonb;begin
 if not private.has_role('admin') then raise exception 'Master account access required';end if;
 result:=public.company_master_dashboard_before_ecommerce();
 return result||jsonb_build_object('credited_ecommerce_mio',(select coalesce(sum(amount),0) from public.ecommerce_rewards where status='posted'),'held_ecommerce_mio',(select coalesce(sum(amount),0) from public.ecommerce_rewards where status in('held_activation','pending_delivery')),
 'top_network',coalesce((select jsonb_agg(x) from(select m.full_name,m.member_code,sum(e.amount) income from (select beneficiary_id,payable_amount amount from public.bonus_transactions where status='posted' union all select beneficiary_id,amount from public.ecommerce_rewards where status='posted')e join public.member_profiles m on m.user_id=e.beneficiary_id where m.user_id<>(select company_id from private.network_foundation where singleton) group by m.user_id order by sum(e.amount) desc limit 10)x),'[]'));
end $$;
revoke all on function public.company_master_dashboard_before_ecommerce() from public,anon,authenticated;
revoke all on function public.company_master_dashboard() from public,anon;grant execute on function public.company_master_dashboard() to authenticated;

revoke all on function private.company_treasury_sources() from public,anon,authenticated;
