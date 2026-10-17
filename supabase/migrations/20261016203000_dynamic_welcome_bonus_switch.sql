-- Admin-controlled Welcome Bonus availability.
-- The current setting is captured once, at a member's first approved package
-- activation, so later setting changes never alter an offer already started.
insert into public.system_config(config_key,version,config_value,effective_from)
values('WELCOME_BONUS',1,'true'::jsonb,clock_timestamp())
on conflict(config_key,version) do nothing;

create table if not exists private.member_welcome_bonus_eligibility (
 member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
 enabled boolean not null,
 started_at timestamptz,
 ends_at timestamptz,
 decided_at timestamptz not null default clock_timestamp(),
 check ((enabled and started_at is not null and ends_at=started_at+interval '15 days')
     or (not enabled and started_at is null and ends_at is null))
);

revoke all on table private.member_welcome_bonus_eligibility from public,anon,authenticated;

-- Preserve every offer that had already started before this switch existed.
insert into private.member_welcome_bonus_eligibility(member_id,enabled,started_at,ends_at,decided_at)
select member_id,true,starts_at,starts_at+interval '15 days',clock_timestamp()
from (
 select member_id,min(coalesce(activated_at,requested_at)) starts_at
 from public.package_activations
 where status='approved'
 group by member_id
) existing
on conflict(member_id) do nothing;

create or replace function private.capture_welcome_bonus_eligibility()
returns trigger language plpgsql security definer set search_path='' as $$
declare is_enabled boolean; starts timestamptz;
begin
 if new.status<>'approved' or (tg_op='UPDATE' and old.status='approved') then return new; end if;
 if exists(select 1 from private.member_welcome_bonus_eligibility where member_id=new.member_id) then return new; end if;
 select coalesce(config_value,'true'::jsonb)='true'::jsonb into is_enabled
 from public.system_config
 where config_key='WELCOME_BONUS' and effective_to is null
 order by version desc limit 1;
 is_enabled:=coalesce(is_enabled,true);
 starts:=coalesce(new.activated_at,new.requested_at,clock_timestamp());
 insert into private.member_welcome_bonus_eligibility(member_id,enabled,started_at,ends_at)
 values(new.member_id,is_enabled,case when is_enabled then starts end,case when is_enabled then starts+interval '15 days' end)
 on conflict(member_id) do nothing;
 return new;
end $$;

drop trigger if exists capture_welcome_bonus_eligibility on public.package_activations;
create trigger capture_welcome_bonus_eligibility
after insert or update of status on public.package_activations
for each row execute function private.capture_welcome_bonus_eligibility();

create or replace function private.activation_offer_window(p_member uuid,p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
 with decision as (
  select enabled,started_at,ends_at
  from private.member_welcome_bonus_eligibility
  where member_id=p_member
 ), current_plan as (
  select private.package_eligible(p_member) eligible,
   coalesce((private.current_mlm_rules()->'plans'->private.current_package_code(p_member)->>'direct_rate')::numeric,0) normal_rate
 ), current_setting as (
  select coalesce((select config_value='true'::jsonb from public.system_config
   where config_key='WELCOME_BONUS' and effective_to is null order by version desc limit 1),true) feature_enabled
 )
 select jsonb_build_object(
  'starts_at',d.started_at,
  'ends_at',d.ends_at,
  'eligible',coalesce(c.eligible and d.enabled and p_at>=d.started_at and p_at<d.ends_at,false),
  'enabled',coalesce(d.enabled,false),
  'enrolled',d.member_id is not null,
  'feature_enabled',s.feature_enabled,
  'normal_rate',c.normal_rate,
  'offer_rate',.40
 )
 from current_plan c cross join current_setting s
 left join (select p_member member_id,decision.* from decision) d on true;
$$;

create or replace function public.admin_set_welcome_bonus(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_enabled is null then raise exception 'Choose whether the Welcome Bonus is on or off'; end if;
 perform pg_advisory_xact_lock(hashtextextended('welcome-bonus-setting',0));
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='WELCOME_BONUS';
 update public.system_config set effective_to=clock_timestamp()
 where config_key='WELCOME_BONUS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('WELCOME_BONUS',v,to_jsonb(p_enabled),clock_timestamp(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'WELCOME_BONUS_SET','system_config',jsonb_build_object('enabled',p_enabled,'version',v));
 return jsonb_build_object('enabled',p_enabled,'version',v);
end $$;

revoke all on function private.capture_welcome_bonus_eligibility(),private.activation_offer_window(uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.admin_set_welcome_bonus(boolean) from public,anon;
grant execute on function public.admin_set_welcome_bonus(boolean) to authenticated;
notify pgrst,'reload schema';
