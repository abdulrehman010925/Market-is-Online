-- Paid package points are chart allocations, not additional cash incentives.
-- Shopping activation has no fresh paid funding and therefore creates no synthetic points.
create function private.credit_paid_package_points(aid uuid) returns void language plpgsql security definer set search_path='' as $$begin
 insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
 select a.member_id,k.kind,k.amount,a.id,'credit','activation:'||a.id||':'||k.kind
 from public.package_activations a cross join lateral(values('BV',a.bv),('DP',a.dp),('GP',a.gp),('BRP',a.brp))k(kind,amount)
 where a.id=aid and a.status='approved' and a.source<>'SHOPPING_PPV' and k.amount>0
 and not exists(select 1 from public.point_ledger p where p.member_id=a.member_id and p.point_type=k.kind and p.source_activation_id=a.id and p.entry_kind='credit') on conflict do nothing;
end $$;
create or replace function private.assign_activation_points() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='approved' and new.source<>'SHOPPING_PPV' then perform private.credit_paid_package_points(new.id);perform private.credit_activation_bonuses(new.id);end if;return new;
end $$;
revoke all on function private.credit_paid_package_points(uuid) from public,anon,authenticated;
-- Existing member IDs, package debits and point history remain intact.
-- Attach the approved rules to old events and award only entirely missing distributions.
do $$declare a record;cfg jsonb:=private.current_mlm_rules();posted integer:=0;preserved integer:=0;begin
 update public.package_activations set rules_snapshot=cfg where rules_snapshot='{}'::jsonb;
 update public.orders set rules_snapshot=cfg where rules_snapshot='{}'::jsonb;
 for a in select * from public.package_activations where status='approved' and source<>'SHOPPING_PPV' order by activated_at,id loop
  perform private.credit_paid_package_points(a.id);
  perform private.credit_binary_volume(a.id);
  if exists(select 1 from public.bonus_transactions where source_activation_id=a.id) then preserved:=preserved+1;continue;end if;
  perform private.credit_activation_bonuses(a.id);posted:=posted+1;
 end loop;
 perform private.sync_company_treasury();
 insert into public.audit_logs(action,entity_type,after_data) values('EXISTING_PLAN_RULES_RECONCILED','package',jsonb_build_object('rules_version',cfg->>'version','missing_sources_processed',posted,'previously_distributed_sources_preserved',preserved,'wallet_debits_repeated',false,'existing_points_repeated',false,'missing_chart_points_backfilled',true));
end $$;
notify pgrst,'reload schema';
