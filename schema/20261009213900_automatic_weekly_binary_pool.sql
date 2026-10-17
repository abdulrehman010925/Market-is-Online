-- Automatically settle every completed Monday-to-Monday binary period in Pakistan time.
-- The job catches up missed runs, but never closes a partial week.
create or replace function private.run_automatic_binary_pool()
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
 company uuid;
 earliest_event timestamptz;
 completed_through timestamptz;
 cycle_start timestamptz;
 cycle_end timestamptz;
 v_cycle_code text;
 settled integer:=0;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('mio-automatic-binary-pool',0)) then return 0; end if;
 select company_id into company from private.network_foundation where singleton limit 1;
 if company is null then return 0; end if;
 select min(event_at) into earliest_event from(
  select a.activated_at event_at from public.package_activations a where a.status='approved'
  union all
  select s.created_at from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all
  select p.created_at from public.point_ledger p where p.point_type='BP' and p.entry_kind='credit'
 ) events;
 if earliest_event is null then return 0; end if;
 completed_through:=date_trunc('week',now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi';
 select max(ends_at) into cycle_start from public.binary_cycles where status<>'reversed';
 if cycle_start is null then
  cycle_start:=date_trunc('week',earliest_event at time zone 'Asia/Karachi') at time zone 'Asia/Karachi';
 end if;
 if cycle_start>=completed_through then return 0; end if;
 perform set_config('request.jwt.claim.sub',company::text,true);
 while cycle_start<completed_through and settled<100 loop
  cycle_end:=(date_trunc('week',cycle_start at time zone 'Asia/Karachi')+interval '7 days') at time zone 'Asia/Karachi';
  if cycle_end>completed_through then exit; end if;
  v_cycle_code:='AUTO-'||to_char(cycle_start at time zone 'Asia/Karachi','IYYY-"W"IW');
  if not exists(select 1 from public.binary_cycles where binary_cycles.cycle_code=v_cycle_code) then
   perform public.admin_close_binary_cycle(v_cycle_code,cycle_start,cycle_end,'Asia/Karachi');
   settled:=settled+1;
  end if;
  cycle_start:=cycle_end;
 end loop;
 return settled;
end
$$;
revoke all on function private.run_automatic_binary_pool() from public,anon,authenticated;

-- Enable the managed scheduler when available. Local PostgreSQL test doubles can still
-- load and exercise the settlement function without installing Supabase's extension.
do $$begin
 if to_regclass('cron.job') is null and exists(select 1 from pg_available_extensions where name='pg_cron') then
  execute 'create extension if not exists pg_cron with schema pg_catalog';
 end if;
 if to_regclass('cron.job') is not null then
  execute 'grant usage on schema cron to postgres';
  execute 'grant all privileges on all tables in schema cron to postgres';
  execute $schedule$select cron.schedule('mio-automatic-binary-pool','5 19 * * *','select private.run_automatic_binary_pool();')$schedule$;
 end if;
end$$;
