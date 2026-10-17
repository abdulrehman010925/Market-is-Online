-- External vendor application starts at the company's required 20% proposal.
-- Active accounts retain their known inviter; no redundant code or lineage override.
create or replace function public.submit_vendor_application(p_business text,p_email text,p_phone text,p_categories text,p_description text,p_proposed numeric,p_introducer_code text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare vid uuid; intro uuid; m public.member_profiles%rowtype; consumer boolean; begin
 if auth.uid() is null then raise exception 'Sign in or register with a referral code before applying'; end if;
 select * into m from public.member_profiles where user_id=auth.uid();
 if m.user_id is null or m.status in('suspended','closed') then raise exception 'Active account required'; end if;
 consumer:=exists(select 1 from public.package_activations where member_id=auth.uid() and status='approved');
 if m.status<>'active' and not consumer then raise exception 'Complete account registration with your referral code first'; end if;
 if length(trim(coalesce(p_business,''))) not between 2 and 150 or p_email not like '%@%' or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_categories,'')))<2 then raise exception 'Complete business details'; end if;
 if p_proposed is distinct from 0.20 then raise exception 'Proposed vendor commission must be 20 percent'; end if;
 intro:=m.sponsor_id;
 insert into public.vendor_applications(applicant_user_id,business_name,contact_email,contact_phone,categories,description,proposed_commission,introduced_by) values(auth.uid(),trim(p_business),trim(p_email),trim(p_phone),trim(p_categories),p_description,0.20,intro) returning id into vid;
 return vid;
end $$;
alter table public.products add column compare_at_price_pkr numeric(14,2) check(compare_at_price_pkr>=0);
alter table public.order_items add column compare_at_price_pkr_snapshot numeric(14,2),add column retail_saving_pkr numeric(18,2) not null default 0;
create function private.snapshot_retail_price() returns trigger language plpgsql security definer set search_path='' as $$ begin
 select compare_at_price_pkr into new.compare_at_price_pkr_snapshot from public.products where id=new.product_id;
 new.retail_saving_pkr:=greatest(coalesce(new.compare_at_price_pkr_snapshot,new.unit_price_pkr)-new.unit_price_pkr,0)*new.quantity;
 return new;
end $$;
create trigger snapshot_retail_price before insert on public.order_items for each row execute function private.snapshot_retail_price();
revoke all on function private.snapshot_retail_price() from public,anon,authenticated;
-- Published compare-at values describe source sale prices, never a second deduction.
notify pgrst,'reload schema';
