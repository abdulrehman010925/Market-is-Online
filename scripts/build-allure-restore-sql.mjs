import { readFileSync } from 'node:fs';

const catalogue = JSON.parse(readFileSync(new URL('../imports/allure-care-catalogue.json', import.meta.url), 'utf8')).products;
const prices = new Map(JSON.parse(readFileSync(new URL('../imports/allure-care-prices-2026-10-02.json', import.meta.url), 'utf8')).products.map(product => [product.sku, product]));
const rows = catalogue.map(product => ({
  ...product,
  price_pkr: prices.get(product.sku)?.price ?? product.price_pkr,
  compare_at_price_pkr: prices.get(product.sku)?.compare_at ?? null,
}));
const data = JSON.stringify(rows).replaceAll('$allure$', '$all ure$');

process.stdout.write(`begin;
insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,reviewed_by,reviewed_at,is_company_owned,commission_rate,awarded_rate,logo_url,source_url)
select n.company_id,'Allure Care',a.email,'','Allure Care — skincare and personal care products.','active',n.company_id,now(),true,.30,.25,'https://mlm-phase1-portal.saifullahnisar5.chatgpt.site/allure-care/logo.png','https://allurecarein.com/'
from private.network_foundation n join auth.users a on a.id=n.company_id
on conflict(owner_user_id,business_name) do update set status='active',reviewed_by=excluded.reviewed_by,reviewed_at=excluded.reviewed_at,is_company_owned=true,commission_rate=.30,awarded_rate=.25,logo_url=excluded.logo_url,source_url=excluded.source_url;

insert into public.products(vendor_id,sku,name,description,category,price_pkr,compare_at_price_pkr,stock_quantity,status,image_url,image_urls,source_url,source_details,review_note)
select v.id,x.sku,x.name,x.description,x.category,x.price_pkr,x.compare_at_price_pkr,
 case when x.price_pkr>0 then 300 else 0 end,
 case when x.price_pkr>0 then 'approved'::public.product_status else 'archived'::public.product_status end,
 x.image_url,coalesce(x.image_urls,'[]'::jsonb),x.source_url,x.source_details,x.review_note
from jsonb_to_recordset($allure$${data}$allure$::jsonb)
as x(sku text,name text,description text,category text,price_pkr numeric,compare_at_price_pkr numeric,image_url text,image_urls jsonb,source_url text,source_details jsonb,review_note text)
cross join public.vendors v join private.network_foundation n on n.company_id=v.owner_user_id
where v.business_name='Allure Care' and v.is_company_owned
on conflict(vendor_id,sku) do update set
 name=excluded.name,description=excluded.description,category=excluded.category,price_pkr=excluded.price_pkr,
 compare_at_price_pkr=excluded.compare_at_price_pkr,stock_quantity=excluded.stock_quantity,status=excluded.status,
 image_url=excluded.image_url,image_urls=excluded.image_urls,source_url=excluded.source_url,
 source_details=excluded.source_details,review_note=excluded.review_note,updated_at=now();

delete from public.featured_products;
insert into public.featured_products(position,product_id,selected_by)
select x.pos,p.id,n.company_id
from (values
 (1,'ALLURE-10608418160918'),(2,'ALLURE-10608277586198'),(3,'ALLURE-10608277356822'),
 (4,'ALLURE-10608272343318'),(5,'ALLURE-10608270442774'),(6,'ALLURE-10608270311702')
) x(pos,sku)
join public.products p on p.sku=x.sku and p.status='approved'
cross join private.network_foundation n;

update public.system_config set effective_to=now()
where config_key='MARKETPLACE_FEATURED_CATEGORIES' and effective_to is null;
insert into public.system_config(config_key,version,config_value,effective_from,created_by)
select 'MARKETPLACE_FEATURED_CATEGORIES',
 coalesce((select max(version)+1 from public.system_config where config_key='MARKETPLACE_FEATURED_CATEGORIES'),1),
 jsonb_build_array(
  jsonb_build_object('category','Skincare','product_ids',
   (select jsonb_agg(id order by sku) from (select id,sku from public.products where category='Skincare' and status='approved' and stock_quantity>0 order by sku limit 3) skincare)),
  jsonb_build_object('category','Hair & beard care','product_ids',
   (select jsonb_agg(id order by sku) from (select id,sku from public.products where category='Hair & beard care' and status='approved' and stock_quantity>0 order by sku limit 3) hair))
 ),now(),n.company_id
from private.network_foundation n;
commit;
`);
