CREATE OR REPLACE FUNCTION private.post_network_bonus(oid uuid, aid uuid, who uuid, kind bonus_method, d integer, b numeric, nominal numeric, amount numeric, cfg jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare tx uuid;state text;begin
 if amount<=0 then return;end if; if oid is not null and exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=who) then return;end if;
 insert into public.bonus_transactions(beneficiary_id,method,source_order_id,source_activation_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
 values(who,kind,oid,aid,d,b,case when b>0 then amount/b else 0 end,nominal,amount,'MIO','editable-plans-v1',jsonb_build_object('plan_rules',cfg,'nominal_mio',nominal,'funded_mio',amount,'depth',d),'mlm:'||coalesce(oid,aid)||':'||kind||':'||who||':'||d) on conflict(idempotency_key) do nothing returning id,status into tx,state;
 if tx is not null and state='posted' then
 update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=who;if not found then raise exception 'Recipient wallet missing';end if;
 insert into public.mio_ledger(member_id,amount,action,source_order_id,activation_id,bonus_transaction_id,reason,idempotency_key) values(who,amount,'bonus_credit',oid,aid,tx,'Plan network bonus','bonus:'||tx);
 end if;
end $function$;

CREATE OR REPLACE FUNCTION private.distribute_mlm_event(member uuid, b numeric, oid uuid, aid uuid, cfg jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare total numeric;scale numeric;amount numeric;r record;p uuid;current_member uuid:=member;side text;d integer:=0;plan jsonb;rates jsonb;cum numeric;prev numeric;direct_paid numeric:=0;gen_paid numeric:=0;sl numeric:=0;slscale numeric:=1;
 dp_base numeric:=b;gp_base numeric:=trunc(b*.5,4);bp_base numeric:=trunc(b*.5,4);gen_cap numeric;placement_cap numeric;
begin
 if oid is not null then select s.dp,s.gp,s.bp into dp_base,gp_base,bp_base from public.shopping_reward_events s where s.order_id=oid;
 elsif aid is not null then select a.dp,a.gp,a.bp into dp_base,gp_base,bp_base from public.package_activations a where a.id=aid;end if;
 dp_base:=coalesce(dp_base,b);gp_base:=coalesce(gp_base,trunc(dp_base*coalesce((cfg->>'generation_plan_rate')::numeric,.5),4));bp_base:=coalesce(bp_base,trunc(dp_base*coalesce((cfg->>'binary_plan_rate')::numeric,.5),4));
 gen_cap:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);placement_cap:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);
 select coalesce(sum(nominal),0) into total from private.mlm_point_candidates(member,dp_base,gp_base,cfg) where method='generation';
 scale:=case when total>0 then least(1,gen_cap/total) else 0 end;
 for r in select * from private.mlm_point_candidates(member,dp_base,gp_base,cfg) order by depth loop
  if r.method='direct' then amount:=trunc(r.nominal,4);direct_paid:=direct_paid+amount;else amount:=trunc(r.nominal*scale,4);gen_paid:=gen_paid+amount;end if;
  perform private.post_network_bonus(oid,aid,r.beneficiary,r.method,r.depth,r.qualifying_base,r.nominal,amount,cfg);
 end loop;
 select coalesce(sum(bp_base*coalesce((cfg->'plans'->private.current_package_code(x.id)->'single_line_rates'->>(x.depth-1))::numeric,0)),0) into total from (
  with recursive chain(id,depth,path) as(
   select q.parent_id,1,array[member,q.parent_id] from public.binary_placements q where q.member_id=member and q.parent_id is not null
   union all select q.parent_id,c.depth+1,c.path||q.parent_id from chain c join public.binary_placements q on q.member_id=c.id where q.parent_id is not null and c.depth<1000 and not q.parent_id=any(c.path)
  )select * from chain
 )x where private.package_eligible(x.id) and x.depth<=coalesce((cfg->'plans'->private.current_package_code(x.id)->>'single_line_levels')::integer,0);
 slscale:=case when total>0 then least(1,placement_cap/total) else 0 end;
 loop
  select q.parent_id,q.side into p,side from public.binary_placements q where q.member_id=current_member;exit when p is null;d:=d+1;if d>1000 then raise exception 'Placement ancestry exceeds supported depth';end if;
  if oid is not null and trunc(bp_base,4)>0 and not exists(select 1 from public.orders where id=oid and reward_version=2 and selling_affiliate_id is not null and buyer_id=p) then
   insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(bp_base,4),side,oid,'credit','shopping-bp:'||oid||':'||p) on conflict(idempotency_key) do nothing;end if;
  plan:=cfg->'plans'->private.current_package_code(p);
  if private.package_eligible(p) and d<=coalesce((plan->>'single_line_levels')::integer,0) then
   rates:=plan->'single_line_rates';select coalesce(sum(value::numeric),0) into cum from jsonb_array_elements_text(rates) with ordinality where ordinality<=d;select coalesce(sum(value::numeric),0) into prev from jsonb_array_elements_text(rates) with ordinality where ordinality<d;
   amount:=case when slscale=1 then trunc(round(bp_base*cum,12),4)-trunc(round(bp_base*prev,12),4) else trunc(bp_base*coalesce((rates->>(d-1))::numeric,0)*slscale,4) end;
   amount:=least(amount,greatest(0,placement_cap-sl));perform private.post_network_bonus(oid,aid,p,'single_line',d,bp_base,bp_base*coalesce((rates->>(d-1))::numeric,0),amount,cfg);sl:=sl+amount;end if;
  current_member:=p;
 end loop;
 return jsonb_build_object('direct',direct_paid,'generation',gen_paid,'direct_generation',direct_paid+gen_paid,'single_line',sl,'dp',dp_base,'gp',gp_base,'bp',bp_base);
end$function$;

