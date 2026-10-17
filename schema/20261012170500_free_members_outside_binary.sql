-- Free registrations remain visible in the sponsor/generation relationship,
-- but cannot sponsor a team or occupy a binary position until a plan is active.
create or replace function private.enforce_package_membership()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sponsor_id is not null and (tg_op = 'INSERT' or new.sponsor_id is distinct from old.sponsor_id)
     and not private.package_eligible(new.sponsor_id)
     and not exists (select 1 from public.user_roles where user_id = new.sponsor_id and role = 'admin') then
    raise exception 'This referral is locked. The sponsor must activate a plan before building a team';
  end if;
  if new.status = 'active'
     and not exists (select 1 from public.user_roles where user_id = new.user_id and role = 'admin')
     and not exists (select 1 from public.package_activations where member_id = new.user_id and status = 'approved') then
    new.status := 'inactive';
  end if;
  return new;
end;
$$;

create or replace function private.place_signup_binary()
returns trigger language plpgsql security definer set search_path = '' as $$
declare side text;
begin
  select raw_user_meta_data ->> 'referral_side' into side from auth.users where id = new.user_id;
  if private.package_eligible(new.user_id) and new.sponsor_id is not null and side is not null then
    perform private.place_outermost(new.user_id, new.sponsor_id, upper(side));
  end if;
  return new;
end;
$$;

create or replace function private.place_binary_after_activation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare sponsor uuid; side text; company uuid;
begin
  if new.status <> 'approved' or not private.package_eligible(new.member_id)
     or exists (select 1 from public.binary_placements where member_id = new.member_id) then return new; end if;
  if exists(select 1 from public.user_roles where user_id=new.member_id and role='admin') then return new; end if;
  select company_id into company from private.network_foundation where singleton and founder_id=new.member_id;
  if company is not null then
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
    values(new.member_id,null,null,company) on conflict(member_id) do nothing;
    return new;
  end if;
  select m.sponsor_id, u.raw_user_meta_data ->> 'referral_side' into sponsor, side
  from public.member_profiles m join auth.users u on u.id = m.user_id where m.user_id = new.member_id;
  if sponsor is not null and side is not null then perform private.place_outermost(new.member_id, sponsor, upper(side)); end if;
  return new;
end;
$$;
drop trigger if exists ab0_place_binary_after_activation on public.package_activations;
create trigger ab0_place_binary_after_activation after insert or update of status on public.package_activations
for each row execute function private.place_binary_after_activation();

create or replace function public.lookup_side_referral(p_code text)
returns table(member_code text, full_name text, placement_side text)
language sql stable security definer set search_path = '' as $$
  select m.member_code,m.full_name,case right(upper(trim(p_code)),2) when '-L' then 'LEFT' when '-R' then 'RIGHT' else null end
  from public.member_profiles m
  where (upper(m.referral_code)=regexp_replace(upper(trim(p_code)),'-[LR]$','') or upper(m.member_code)=regexp_replace(upper(trim(p_code)),'-[LR]$',''))
    and private.package_eligible(m.user_id)
    and not exists(select 1 from public.user_roles r where r.user_id=m.user_id and r.role='admin');
$$;
revoke all on function private.place_binary_after_activation() from public,anon,authenticated;
revoke all on function public.lookup_side_referral(text) from public,anon;
grant execute on function public.lookup_side_referral(text) to authenticated;
notify pgrst,'reload schema';
