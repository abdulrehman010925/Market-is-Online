# Market is Online — Complete Handover and Migration Guide

Updated: 26 October 2026

This package contains the production website code, database migrations, tests, marketplace assets, and the business rules used by the current Market is Online system.

## What is included

- `dist/` — ready-to-upload production website, including marketplace images and icons.
- `schema/` — the complete ordered PostgreSQL/Supabase schema and all current migrations.
- `tests/` — database-rule and interface regression tests.
- `imports/` — product catalogue import data used during development.
- `public/` — shared public branding asset.
- `NETWORK_RULES.md` — the implemented MLM and e-commerce rules.
- `QA_REVIEW.md` and `SETUP_GUIDE.md` — technical verification and setup notes.
- `handover/configure-supabase.mjs` — safely points the frontend to a different Supabase project.
- `handover/SECOND_CHATGPT_PROMPT.txt` — a ready prompt for continuing development from another ChatGPT account.

The archive deliberately excludes Git history, temporary deployment archives, dependencies (`node_modules`), passwords, service-role keys, database passwords, and private user-data dumps.

## Recommended method: transfer the same Supabase project

Use this when you want the entire current system under a different Supabase account. It is the simplest and safest route because the project itself moves; nothing is copied.

It preserves:

- Auth users and password hashes
- database tables, functions, triggers, RLS policies, extensions and scheduled jobs
- member network and binary placements
- vendors, products, listings, orders and earnings
- Storage buckets and all uploaded product/profile/banner images
- the project URL and API keys, so the frontend normally needs no Supabase code change

Steps:

1. Sign in to the new Supabase account and create or choose its target organization.
2. Make the current/source Supabase account a member of that target organization temporarily.
3. In the current Supabase project open `Project Settings → General → Transfer project`.
4. Select the target organization and confirm the transfer.
5. Sign in with the new account and verify the project, Auth users, Storage buckets, products and orders.
6. Remove the old account from the target organization only after every check passes.

The source account must own the source organization and be a member of the target organization. Supabase may briefly interrupt a transfer when moving from a paid plan to Free.

## Alternative: migrate into a completely new Supabase project

Choose this only if you need a new project reference, new region, or a clean infrastructure project.

1. Create the new Supabase project in the required region.
2. Follow Supabase’s official “Migrating within Supabase” backup/restore process. A full restore can include the database schema, all data, Auth accounts and hashed passwords.
3. Copy Storage objects separately. Restoring the database copies `storage.objects` metadata but not the actual image bytes. Use Supabase’s official Storage migration script, CLI, or S3-compatible `rclone` copy.
4. Reconfigure Auth site URL, redirect URLs, SMTP, email templates, Realtime settings, extensions, scheduled jobs and any external integrations.
5. Point the website at the new project using the included configuration helper.
6. Test the checklist below before switching the domain.

Do not place a Supabase `service_role`/secret key in browser code. The frontend must use only the project URL and publishable key.

### Point the frontend to a new project

macOS/Linux:

```bash
MIO_SUPABASE_URL="https://NEW_PROJECT_REF.supabase.co" \
MIO_SUPABASE_PUBLISHABLE_KEY="NEW_PUBLISHABLE_KEY" \
node handover/configure-supabase.mjs
```

Windows PowerShell:

```powershell
$env:MIO_SUPABASE_URL="https://NEW_PROJECT_REF.supabase.co"
$env:MIO_SUPABASE_PUBLISHABLE_KEY="NEW_PUBLISHABLE_KEY"
node handover/configure-supabase.mjs
```

The helper updates only `dist/app.js` and creates `dist/app.js.before-supabase-change` as a rollback copy.

## Move the work to another ChatGPT Plus account

1. Download this ZIP.
2. Start a new Work/project conversation in the second ChatGPT account.
3. Upload the ZIP and paste the text from `handover/SECOND_CHATGPT_PROMPT.txt`.
4. Tell the new ChatGPT whether you transferred the existing Supabase project or created a new one.
5. Never paste database passwords, service-role keys, S3 secrets or account passwords into chat. Connect Supabase through its authorized connector or enter secrets directly in the hosting dashboard.

The ChatGPT Site itself is not the database. The source code moves through this ZIP; the live database and uploaded images move through Supabase transfer/migration.

## Deploy the frontend on Namecheap

This website is a static HTML/CSS/JavaScript frontend. Supabase remains the remote backend.

1. Buy/activate Namecheap hosting with cPanel and enable SSL.
2. Open `cPanel → File Manager → public_html`.
3. Upload the **contents inside `dist/`**, not the `dist` folder as another nested folder.
4. Confirm that `public_html/index.html`, `public_html/app.js`, `public_html/styles.css` and all image folders exist.
5. Open the domain and hard-refresh the browser.
6. In Supabase `Authentication → URL Configuration`, set the Site URL to the final HTTPS domain and add its required redirect URLs.
7. Test sign-up, login, password reset, product images, checkout and order history.

## Current database footprint

Measured before handover:

- Database: about 15 MB
- Members: 5
- Vendors: 2
- Products: 31
- Orders: 7
- Storage buckets: 4
- Stored objects: 2
- Stored object bytes: about 308 KB

## Is Supabase Free enough?

The current project easily fits the Free plan. A pilot with 5,000–10,000 registered users can fit if actual monthly activity and ledger growth remain moderate. However, this platform creates order, point, bonus and genealogy records, so database growth depends more on transactions than the raw user count.

The bigger early constraint will likely be product images and image traffic. Five hundred products with several optimized images can approach or exceed the Free plan’s 1 GB file storage or 5 GB monthly egress.

Use Free for development and a controlled pilot. For a serious public launch, use Supabase Pro so the project is not paused for low activity and you receive larger database/storage/egress quotas plus daily backups.

## Mandatory verification before launch

- Sign up through LEFT and RIGHT referral links.
- Confirm automatic binary placement and member-tree visibility.
- Activate each of Starter, Basic, Silver, Gold and Platinum.
- Submit and approve a vendor.
- Submit, approve and display a product with multiple photos.
- Place a COD order and verify Pending → Accepted → Shipped → Delivered.
- Confirm PPV stays on hold until delivery and confirmed payment.
- Verify direct, generation, binary, binary placement and e-commerce earnings.
- Verify inactive earnings stay on hold and withdrawal remains blocked.
- Verify MIO transfers and Premium transfer rules.
- Verify company wallets, pending reserves, leftovers and receipts.
- Verify admin plan editing, featured products/categories, carousel and notification controls.
- Verify password reset, SMTP delivery, Auth redirects and TOTP before launch.
- Back up the new project before changing DNS.

## Rollback rule

Do not delete the old project or change the production domain until the new owner/account has passed the full checklist. Keep a database and Storage backup outside Supabase before any irreversible migration.
