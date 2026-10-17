-- The Founder is sponsored by the Company for the generation relationship,
-- but is the root of the member Binary tree. Activating the Founder must not
-- try to place them on the Company's LEFT or RIGHT side.
create or replace function private.place_binary_after_activation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare sponsor uuid; side text; company uuid;
begin
  if new.status <> 'approved' or not private.package_eligible(new.member_id)
     or exists (select 1 from public.binary_placements where member_id = new.member_id) then
    return new;
  end if;

  -- Company/Admin remains outside Binary even if it activates a package.
  if exists(select 1 from public.user_roles where user_id=new.member_id and role='admin') then
    return new;
  end if;

  -- The Founder becomes the Binary root on first paid activation. No side is
  -- required and the Company is recorded only as the account that placed it.
  select company_id into company
  from private.network_foundation
  where singleton and founder_id=new.member_id;
  if company is not null then
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
    values(new.member_id,null,null,company)
    on conflict(member_id) do nothing;
    return new;
  end if;

  select m.sponsor_id,u.raw_user_meta_data->>'referral_side' into sponsor,side
  from public.member_profiles m
  join auth.users u on u.id=m.user_id
  where m.user_id=new.member_id;
  if sponsor is not null and side is not null then
    perform private.place_outermost(new.member_id,sponsor,upper(side));
  end if;
  return new;
end;
$$;

revoke all on function private.place_binary_after_activation() from public,anon,authenticated;
notify pgrst,'reload schema';
