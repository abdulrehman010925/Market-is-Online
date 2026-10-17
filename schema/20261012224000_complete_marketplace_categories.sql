-- Keep the Company registry usable in a clean pre-founder state.
alter table private.network_foundation alter column founder_id drop not null;

-- Complete marketplace category catalog. Existing product category names remain valid.
do $$
declare
  company uuid;
  next_version integer;
  categories jsonb := '[
    {"name":"Electronics & Accessories","slug":"electronics","icon":"electronics"},
    {"name":"Mobiles & Tablets","slug":"mobiles-tablets","icon":"electronics"},
    {"name":"Computers & Gaming","slug":"computers-gaming","icon":"electronics"},
    {"name":"TV, Audio & Cameras","slug":"tv-audio-cameras","icon":"electronics"},
    {"name":"Women’s Fashion","slug":"womens-fashion","icon":"womens-fashion"},
    {"name":"Men’s Fashion","slug":"mens-fashion","icon":"mens-fashion"},
    {"name":"Kids & Baby","slug":"kids-baby","icon":"toys"},
    {"name":"Shoes & Footwear","slug":"shoes-footwear","icon":"mens-fashion"},
    {"name":"Bags & Luggage","slug":"bags-luggage","icon":"womens-fashion"},
    {"name":"Jewellery & Watches","slug":"jewellery-watches","icon":"jewellery"},
    {"name":"Beauty & Personal Care","slug":"beauty-personal-care","icon":"beauty"},
    {"name":"Skincare","slug":"skincare","icon":"skincare"},
    {"name":"Hair & beard care","slug":"hair-beard-care","icon":"hair-beard-care"},
    {"name":"Skincare bundles","slug":"skincare-bundles","icon":"skincare-bundles"},
    {"name":"Health & Wellness","slug":"health-wellness","icon":"health"},
    {"name":"Home & Living","slug":"home-living","icon":"home-living"},
    {"name":"Kitchen & Dining","slug":"kitchen-dining","icon":"home-living"},
    {"name":"Furniture & Decor","slug":"furniture-decor","icon":"home-living"},
    {"name":"Grocery & Food","slug":"grocery-food","icon":"grocery"},
    {"name":"Sports & Outdoors","slug":"sports-outdoors","icon":"sports"},
    {"name":"Toys & Games","slug":"toys-games","icon":"toys"},
    {"name":"Books & Stationery","slug":"books-stationery","icon":"books"},
    {"name":"Automotive & Motorbike","slug":"automotive-motorbike","icon":"automotive"},
    {"name":"Tools & Home Improvement","slug":"tools-home-improvement","icon":"home-living"},
    {"name":"Pet Supplies","slug":"pet-supplies","icon":"health"},
    {"name":"Office & Business Supplies","slug":"office-business-supplies","icon":"books"},
    {"name":"Travel & Outdoor","slug":"travel-outdoor","icon":"sports"}
  ]'::jsonb;
begin
  select m.user_id into company
  from public.member_profiles m
  join public.user_roles r on r.user_id=m.user_id and r.role='admin'
  order by m.created_at
  limit 1;

  select coalesce(max(version),0)+1 into next_version
  from public.system_config
  where config_key='MARKETPLACE_CATEGORIES';

  update public.system_config
  set effective_to=clock_timestamp()
  where config_key='MARKETPLACE_CATEGORIES' and effective_to is null;

  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
  values('MARKETPLACE_CATEGORIES',next_version,categories,clock_timestamp(),company);
end
$$;
