# Market is Online — Phase 1

Private Site storefront and member portal backed by Supabase Postgres/Auth. The database starts with package configuration only: no sample members, sellers, products, orders, balances, or earnings are seeded.

## Phase 1 included

- Signup with verified referral-code lookup, member/referral IDs, consent timestamp/version, login, password reset, and sponsor attribution.
- PKR marketplace, real seller applications, seller product submissions, admin listing review, COD orders, stock locking, and admin payment confirmation.
- Shopping PPV is calculated from company-approved, snapshotted product PPV only after admin payment confirmation. Unpaid COD orders earn no PPV.
- PPV remains in the member PPV ledger; each package activation also credits its package PPV. Auto activation can proceed through Advanced 2. Premium ($500 base / $550 payable) can only be activated directly with MIO Points.
- Separate MIO wallet and immutable entries. Package purchases debit MIO; Direct, Generation, and Binary Pool Share credits post in MIO.
- Admin may mint or burn points only in the signed-in admin's own wallet. Member transfers require one side to hold Premium; company may send to every active member; incoming company transfers require the member side to hold Premium.
- Side-referral outermost placement plus legacy assisted placement, BP propagation through the binary ancestry, and admin-closed weekly pool at 35%. Full share is 50 BP per side; unmatched volume carries forward; zero-share pools remain unallocated.
- Six or fewer featured positions are admin-selected and restricted by database rules to approved Market is Online-owned products. Other marketplace listings rotate across sellers; SEO metadata supports search-engine indexing and does not control storefront rank.

## Database

Supabase project: `market-is-online-phase1` (`vdkhqqhonpnsqugoadke`, Mumbai). The project was created at the cost confirmed by the owner. SQL migrations are under `schema/` and have been applied:

1. `001_phase1_postgres.sql` — member, package, marketplace, genealogy, bonus and audit schema.
2. `002_mio_marketplace_rules.sql` — MIO wallet/transfer and six featured positions.
3. `003_marketplace_operations.sql` — admin review, PKR/USD rate snapshots, orders and PPV activation.
4. `004_transfer_by_member_code.sql` — transfer by member/referral code.
5. `005_phase1_direct_generation.sql` — Direct/Generation payouts in MIO; Gen 1 does not stack with Direct under the current supplied config.
6. `006_binary_placement_and_pool.sql` — Left/Right placement, BP ancestry, 35% weekly pool.
7. `007_signup_referrals_and_consent.sql` — required signup consent and referral validation; direct referral listing.
8. `008_policy_and_index_cleanup.sql` — foreign-key indexes and consolidated product/vendor read policies.
9. `009_activation_point_assignment.sql` — BV, DP, GP, BRP assignment and activation-triggered earning calculation.

RLS is enabled on public tables. Financial changes use server-side SQL functions with user/role checks; the client contains only the Supabase publishable key. Never place a service-role key in this site.

## First admin and launch configuration

1. Create the owner account through **Join free**, confirm the email if Supabase Auth requests it, and sign in.
2. In the Supabase SQL Editor, promote only that verified owner account (replace the UUID with the owner account ID):

   ```sql
   insert into public.user_roles(user_id, role)
   values ('OWNER_AUTH_USER_UUID', 'admin')
   on conflict (user_id, role) do nothing;
   ```

3. Refresh the site. The Admin area becomes visible.
4. Set the USD/PKR reference rate and its source before taking marketplace orders. This rate is snapshotted per order and converts paid PKR shopping into PPV.
5. Create or approve a company-owned seller account, add real inventory, review listing details, then select up to six company-owned products for Featured.
6. Assign binary placements before running a weekly cycle. Admin confirms COD payment before PPV is posted. Close non-overlapping weekly cycles with the correct period/timezone.

## Not connected yet

- Member MIO point purchases/top-ups and external payment settlement. The interface keeps top-up disabled until a payment provider and settlement/reconciliation process are configured.
- Seller payout/commission, shipping charges and delivery coverage, refund/reversal policy, and email sender/domain settings.
- The supplied framework contains additional payout methods beyond Phase 1; they are not enabled in this Phase 1 application.
- The 35% binary pool uses the Phase 1 document's active-package/full-share qualification, 50 BP each side, package entitlement, and carried volume. Review this operational assumption and local legal treatment before public financial launch.
- Terms and privacy wording still needs the company's final approved text; the signup consent record is versioned, but this repository does not invent legal terms.

## Source files

- `dist/index.html`, `dist/app.js`, `dist/styles.css` — static application and Supabase client.
- `public/market-is-online-logo.png` — supplied company logo.
- `schema/*.sql` — applied, versioned Postgres migrations.

## Current verification and pending fixes

See [QA_REVIEW.md](QA_REVIEW.md) for instruction coverage, 73 passing isolated checks, known live defects and remaining launch work. Run `npm ci`, `npm run check`, and `npm test`. Migrations 010 and 011 are tested locally and await explicit approval before applying to the live database. They are not included in the previously applied 001–009 list above. The site remains private.

## October 2 release

[NETWORK_RULES.md](NETWORK_RULES.md) is the current rule/framework reference and supersedes outdated status notes above. Existing company and Abdul Rehman accounts are confirmed. The timestamped migrations add founder protections, side referrals, single-line income, product PPV approval and seller income/withdrawals. Current source validation: 142 passing checks.

The latest control centre organizes operations into explained task sections. External seller applications negotiate and accept commission before approval; company brands have zero commission and can share one company owner. Vendors upload product photos, save drafts and submit for company PPV approval. Allure Care's 31 imported products are pending manual review. Read the latest section of NETWORK_RULES.md for the six-share commission, discount, attribution and PKR payout rules.
