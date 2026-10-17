begin;

update public.package_versions
set display_name = case package_code
  when 'BASIC_1' then 'Starter'
  when 'BASIC_2' then 'Basic'
  when 'ADVANCED_1' then 'Silver'
  when 'ADVANCED_2' then 'Gold'
  when 'PREMIUM' then 'Platinum'
  else display_name
end
where package_code in ('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM');

update public.system_config
set config_value = jsonb_set(
  jsonb_set(config_value, '{plans,BASIC_1,display_name}', '"Starter"'::jsonb, true),
  '{plans,BASIC_2,display_name}', '"Basic"'::jsonb, true
)
where config_key = 'MLM_PLANS'
  and effective_to is null;

commit;
