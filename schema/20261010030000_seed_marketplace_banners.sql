do $$
declare current jsonb; v integer;
begin
 select config_value into current from public.system_config
 where config_key='MARKETPLACE_HERO' and effective_to is null
 order by version desc limit 1;
 if current is null or current='[]'::jsonb then
  update public.system_config set effective_to=clock_timestamp()
  where config_key='MARKETPLACE_HERO' and effective_to is null;
  select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_HERO';
  insert into public.system_config(config_key,version,config_value,effective_from)
  values('MARKETPLACE_HERO',v,'[
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/home-living-campaign.webp","title":"Make room for good living","subtitle":"Thoughtful finds for every corner of home.","cta_label":"Explore home","cta_link":"#catalog"},
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/winter-edit-campaign.webp","title":"Find your next favourite","subtitle":"Style, care and everyday essentials from local sellers.","cta_label":"Shop the edit","cta_link":"#catalog"},
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/sports-campaign.webp","title":"Move with confidence","subtitle":"Explore sports and active essentials.","cta_label":"Shop now","cta_link":"#catalog"},
    {"image_url":"https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/assets/winter-campaign.webp","title":"Your winter edit","subtitle":"Find cozy layers and seasonal favorites.","cta_label":"Explore products","cta_link":"#catalog"}
  ]'::jsonb,clock_timestamp());
 end if;
end $$;
