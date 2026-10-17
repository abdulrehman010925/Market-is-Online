# Member dashboard and activation offer

Implemented 16 October 2026. The storefront product layout and tree rendering
are unchanged. Account presentation lives in `dist/account-dashboard.js` and
`dist/account-dashboard.css`; existing account forms keep their IDs and handlers.

## Direct activation offer

- The first approved plan activation starts one 15-day window (360 hours).
- Upgrades do not restart the window. Inactive members cannot use the offer.
- New direct paid package activations during the window pay the sponsor's
  normal package rate plus the Welcome Bonus rate on the activation's DP.
  The default Welcome Bonus is an extra 10% for every package. The two
  components have separate bonus and ledger records. No generation
  qualification is required for this direct bonus.
- Edit Plans has a versioned ON/OFF switch and rate field (0–10% in 0.01%
  increments). The enabled decision and rate are captured at a member's first
  activation; editing the offer applies to future first activations. Existing
  offers use 10% on future direct events. Posted history is unchanged.
- After expiry, the sponsor's current package rate applies. Source package does
  not determine the sponsor rate. Existing partial-upgrade DP rules remain intact.
- Shopping events, shopping-PPV activation funding and e-commerce rewards keep
  their existing formulas. Historical bonus rows are not repriced.
- Posting remains idempotent through the original ledger keys.
- Existing generation, binary and Stage 1 reserve budgets stay unchanged. If
  their full allocations plus promotional direct bonus exceed the base amount,
  the shortfall is funded from the same activation's admin fee. Company fee
  income is reduced by that use. Allocation above total payment is rejected.
  With the current settings, 100 DP + 10 fee funds up to 40 direct + 70 reserves.
- Receipt calculation traces retain the applied offer flag and event timestamp.

## Presentation and privacy

Public primary navigation contains Marketplace and Membership Plans. My Dashboard
appears after sign-in. Wallet, transfers, histories, network, orders, security and
eligible seller/admin tools use the account sidebar. Mobile uses a menu toggle.
Guest order receipts remain accessible through their private order tokens.

`my_member_dashboard()` has no target-member argument: it reads only the caller's
account and uses existing network permission checks. A generation click displays
that generation's actual member rows, package, status and enrollment date.

Network earnings exclude e-commerce rows. E-commerce is an independent page;
its existing credited rewards continue posting into the existing MIO wallet.
No new withdrawal or wallet-distribution business rule was introduced.

Annual/monthly maintenance and all four future distribution wallets are locked
Coming soon placeholders. Their percentages, fees and actions are not enabled.

Receipts remain available where useful and are rendered from existing records;
opening a receipt does not insert a new database record. Point activity is a
compact inline list without View buttons. Binary receipts show shares and price.

## Verification

- `npm run test:dashboard`: DOM interactions and isolated PostgreSQL tests using
  the exact live distribution/posting functions as baseline fixtures.
- Covers all five package rates, the exact 15-day cutoff, inactive eligibility,
  upgrade behavior, duplicate posting, funding ceiling, company net fee and ACLs.
- Live RPC checked as the authenticated database role without changing balances.
- Existing full migration replay (`npm test`) is blocked by a pre-existing
  textual tree migration error: `Expected graphical tree total BP fragment was
  not found`. The focused tests above do not depend on that historical replay.
- Real browser/device visual QA was unavailable in this environment. Responsive
  rules and mobile menu interactions are covered, but are not a substitute for
  a real-device layout check.

## Permanent account foundation

The company account is the only effective admin. The founder account, SHUJAAT
ALI KHAN, is the company's fixed direct referral and remains a member. Future
requests to reset test activity must retain both accounts, their identities,
authentication, roles, profiles, and this sponsor relationship. A reset may
clear balances, earnings, and transaction history only when specifically
requested, without changing the account foundation. No reset was performed as
part of this dashboard update.
