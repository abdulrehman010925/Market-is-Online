-- Completed registration is not package activation.
create function private.package_eligible(member uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.member_profiles where user_id=member and status='active') and exists(select 1 from public.package_activations where member_id=member and status='approved');
$$;
create function private.enforce_package_membership() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.sponsor_id is not null and (TG_OP='INSERT' or new.sponsor_id is distinct from old.sponsor_id) then
  if not private.package_eligible(new.sponsor_id) and not exists(select 1 from public.user_roles where user_id=new.sponsor_id and role='admin') then raise exception 'Sponsor must activate a package before building a team'; end if;
 end if;
 if new.status='active' and not exists(select 1 from public.user_roles where user_id=new.user_id and role='admin') and not exists(select 1 from public.package_activations where member_id=new.user_id and status='approved') then new.status:='inactive'; end if;
 return new;
end $$;
create trigger zz_package_membership before insert or update on public.member_profiles for each row execute function private.enforce_package_membership();
create function private.activate_package_member() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' then update public.member_profiles set status='active',updated_at=now() where user_id=new.member_id and status='inactive' and terms_accepted_at is not null; end if;return new;
end $$;
create trigger aa_activate_package_member after insert or update of status on public.package_activations for each row execute function private.activate_package_member();
create function private.enforce_bonus_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.payable_amount>0 and new.status='posted' then
  if not private.package_eligible(new.beneficiary_id) then raise exception 'Inactive member cannot receive incentives'; end if;
  if new.source_order_id is not null then select buyer_id into buyer from public.orders where id=new.source_order_id;
  elsif new.source_activation_id is not null then select member_id into buyer from public.package_activations where id=new.source_activation_id; end if;
  if buyer=new.beneficiary_id then raise exception 'Own purchase gives activation PPV only, not an incentive'; end if;
 end if;return new;
end $$;
create trigger aa_bonus_eligibility before insert on public.bonus_transactions for each row execute function private.enforce_bonus_eligibility();
-- Registered inactive members may buy products or a package; suspended/closed remain blocked.
do $$declare f text; sig text;begin
 foreach sig in array array['public.activate_package_with_mio(text,text)','private.place_marketplace_order(jsonb,text,text,text,text,text)','public.request_offline_premium_purchase(text,text,text)'] loop
  f:=pg_get_functiondef(sig::regprocedure);
  f:=replace(f,'user_id=member and status=''active''','user_id=member and status in (''active'',''inactive'') and terms_accepted_at is not null');
  f:=replace(f,'user_id=buyer and status=''active''','user_id=buyer and status in (''active'',''inactive'') and terms_accepted_at is not null');
  f:=replace(f,'user_id=uid and status=''active''','user_id=uid and status in (''active'',''inactive'') and terms_accepted_at is not null');execute f;
 end loop;
 f:=pg_get_functiondef('private.place_signup_binary()'::regprocedure);f:=replace(f,'new.status=''active''','new.status in (''active'',''inactive'')');execute f;
 -- Funding volumes belong to the sale event, not to the buyer's spendable point balances.
 f:=pg_get_functiondef('private.post_shopping_rewards(uuid)'::regprocedure);
 f:=replace(f,'insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)'||chr(10)||' select buyer,k,case when k in(''BV'',''DP'') then b else trunc(b/2,4) end,oid,''credit'',''shopping:''||oid||'':''||k from unnest(array[''BV'',''DP'',''GP'',''BRP'']) k where case when k in(''BV'',''DP'') then b else trunc(b/2,4) end>0;','-- Sale BV funding is stored in shopping_reward_events; buyer only gets PPV.');execute f;
 -- Allow inactive recipients to receive activation funding, not earned incentives.
 f:=pg_get_functiondef('private.mio_transfer(uuid,numeric,text)'::regprocedure);
 f:=replace(f,'user_id=p_recipient_id and status=''active''','user_id=p_recipient_id and status in (''active'',''inactive'') and terms_accepted_at is not null');execute f;
 f:=pg_get_functiondef('public.lookup_transfer_recipient(text)'::regprocedure);
 f:=replace(f,'and m.status=''active''','and m.status in (''active'',''inactive'') and m.terms_accepted_at is not null');execute f;
end $$;
revoke all on function private.package_eligible(uuid),private.enforce_package_membership(),private.activate_package_member(),private.enforce_bonus_eligibility() from public,anon,authenticated;
create or replace function private.assign_activation_points() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' and new.source<>'SHOPPING_PPV' then perform private.credit_activation_bonuses(new.id); end if;return new;
end $$;
create function private.enforce_commission_eligibility() returns trigger language plpgsql security definer set search_path='' as $$declare buyer uuid;begin
 if new.share_kind in ('affiliate','sponsor','second_upline','introducer') and new.beneficiary_id is not null then
  select o.buyer_id into buyer from public.order_items i join public.orders o on o.id=i.order_id where i.id=new.order_item_id;
  if not private.package_eligible(new.beneficiary_id) or new.beneficiary_id=buyer then
   if new.status='paid' then raise exception 'Inactive member or buyer cannot receive this incentive'; end if;
   new.beneficiary_id:=null;new.status:='held';
  end if;
 end if;return new;
end $$;
create trigger aa_commission_eligibility before insert or update on public.commission_allocations for each row execute function private.enforce_commission_eligibility();
revoke all on function private.enforce_commission_eligibility() from public,anon,authenticated;
notify pgrst,'reload schema';
