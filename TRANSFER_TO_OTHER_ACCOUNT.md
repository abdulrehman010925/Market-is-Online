# Market is Online — دوسرے ChatGPT account میں منتقل کرنے کا طریقہ

## ZIP میں کیا شامل ہے

یہ export مکمل editable source ہے:

- `dist/` — تیار frontend، CSS، JavaScript، marketplace assets اور تصاویر
- `supabase/migrations/` — Supabase migrations
- `schema/` — ordered SQL schema اور business rules
- `tests/` — regression/interface/database tests
- `public/`, `imports/`, `scripts/`, `docs/`, `handover/`
- `package.json` اور `package-lock.json`
- `README.md`, `SETUP_GUIDE.md`, `NETWORK_RULES.md`, `QA_REVIEW.md`

`node_modules`, Git history، پرانے deployment archives، passwords اور service-role/private keys جان بوجھ کر شامل نہیں کیے گئے۔

## دوسرے GPT account میں source استعمال کرنا

1. ZIP download کریں۔
2. دوسرے account میں نیا ChatGPT Project/Work conversation کھولیں۔
3. ZIP upload کریں۔
4. یہ prompt بھی paste کریں:

   > یہ Market is Online کا مکمل source export ہے۔ ZIP کو extract کر کے structure سمجھیں۔ Backend formulas، database schema، authentication اور existing business rules کو بغیر اجازت تبدیل نہ کریں۔ پہلے README، SETUP_GUIDE اور handover/MIGRATION_GUIDE پڑھیں۔ اگر اسی Supabase project کو استعمال کرنا ہو تو موجودہ project URL اور publishable key رکھیں؛ اگر نیا project ہو تو migrations، data، Auth اور Storage migration کی مکمل verification کے بعد frontend configure کریں۔

5. اگر دوسرے GPT account میں نئی Site بنانی ہے تو source کو remix/import کر کے نئی Site deploy کریں۔ موجودہ live Site کی editing access خود بخود account بدلنے سے منتقل نہیں ہوتی۔

## سب سے محفوظ Database طریقہ: وہی Supabase project منتقل کریں

اگر مقصد صرف دوسرے account سے اسی website کو manage کرنا ہے تو نیا database نہ بنائیں۔ موجودہ Supabase project کو نئے account کی organization میں transfer کریں:

1. نئے Supabase account میں target organization بنائیں۔
2. موجودہ account کو عارضی طور پر target organization کا member بنائیں۔
3. Supabase Dashboard میں `Project Settings → General → Transfer project` کھولیں۔
4. target organization منتخب کر کے transfer مکمل کریں۔
5. نئے account سے Auth users، tables، products، orders، Storage images اور policies چیک کریں۔
6. verification مکمل ہونے کے بعد پرانے account کی access ہٹائیں۔

اس طریقے سے users، password hashes، wallets، network data، transactions، products، orders اور images وہیں رہتے ہیں۔ یہی recommended طریقہ ہے۔

## اگر نیا Supabase project لازمی ہو

یہ الگ migration ہے اور اس میں data/auth/images کی copy کرنی پڑتی ہے:

1. نئے account میں نیا Supabase project بنائیں۔
2. `supabase/migrations/` کو ترتیب سے run کریں؛ migrations database structure، functions، triggers اور RLS بناتی ہیں۔
3. پرانے project کا database backup/`pg_dump` بنا کر نئے project میں restore کریں۔ UUIDs، member codes اور timestamps برقرار رکھیں۔
4. Auth users الگ migrate کریں۔ عام SQL سے password hashes copy نہ کریں؛ Supabase کے official Auth export/import یا password-reset flow استعمال کریں۔ service-role key صرف secure server/CLI میں رکھیں، browser یا chat میں نہیں۔
5. Storage buckets اور اصل image files الگ copy کریں؛ صرف `storage.objects` rows restore کرنے سے image bytes copy نہیں ہوتیں۔
6. نئے project کی Auth Site URL، redirect URLs، SMTP، Storage policies، Realtime اور scheduled jobs دوبارہ set کریں۔
7. نئے URL اور publishable/anon key سے frontend configure کریں:

```bash
MIO_SUPABASE_URL="https://NEW_PROJECT_REF.supabase.co" \
MIO_SUPABASE_PUBLISHABLE_KEY="NEW_PUBLISHABLE_KEY" \
node handover/configure-supabase.mjs
```

8. نئی Site/hosting میں build publish کر کے login، signup، images، marketplace، checkout، orders، earnings، trees اور admin access test کریں۔

**اہم:** frontend میں صرف Supabase URL اور publishable/anon key ہونی چاہیے۔ `service_role` یا database password کبھی frontend، ZIP یا ChatGPT chat میں نہ رکھیں۔

## Namecheap پر static frontend

`dist/` کے اندر موجود files کو Namecheap cPanel کے `public_html` میں upload کریں؛ `dist` کو nested folder نہ بنائیں۔ Supabase پھر بھی remote backend رہے گا۔ Domain کو Supabase Auth URL Configuration میں add کریں۔

## بہتر فیصلہ

- صرف account بدلنا ہو: **same Supabase project transfer کریں**۔
- نیا project/ref/region چاہیے: نیا project بنا کر مکمل backup، Auth اور Storage migration کریں۔ پرانا project verification تک delete نہ کریں۔
