-- Activation-assigned points beyond PPV. PPV itself remains sourced either
-- by the payment/MIO activation routine or by a paid marketplace order.
create function private.assign_activation_points()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status='approved' then
    insert into public.point_ledger(member_id,point_type,amount,source_activation_id,entry_kind,idempotency_key)
      values
        (new.member_id,'BV',new.bv,new.id,'credit','activation:'||new.id::text||':BV'),
        (new.member_id,'DP',new.dp,new.id,'credit','activation:'||new.id::text||':DP'),
        (new.member_id,'GP',new.gp,new.id,'credit','activation:'||new.id::text||':GP'),
        (new.member_id,'BRP',new.brp,new.id,'credit','activation:'||new.id::text||':BRP')
      on conflict do nothing;
    perform private.credit_activation_bonuses(new.id);
  end if;
  return new;
end;
$$;
revoke all on function private.assign_activation_points() from public, anon, authenticated;
create trigger package_activation_point_assignments
after insert on public.package_activations for each row execute function private.assign_activation_points();
