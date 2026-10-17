# Market is Online Phase 1 review — 1 October 2026

The supplied Phase 1 specification and full formula framework were reread. Later owner instructions take precedence: 35% binary pool, no Direct/Gen-1 stacking, retained cascading PPV through Advanced 2, Premium via MIO only, restricted ordinary transfers, company-set shipping, separate seller commissions, and the approved offline first-Premium purchase flow.

`npm test`: **117 passing checks** — 91 isolated PostgreSQL/PGlite checks and 26 jsdom source interaction checks. `npm run check` validates JavaScript syntax. Tests use temporary records in an isolated database and roll them back; none are copied into the hosted app.

## Implemented and published capabilities

- Mandatory referral validation on normal registration; trusted external identities remain pending until validated onboarding. Google sign-in controls were removed at the owner's request.
- Normal login with a role-gated Workspace; no public operations credential or admin label.
- Native free TOTP enrollment/verification UI. Server wrappers require AAL2 and TOTP verification within two minutes for operations mint/burn and transfers. Each UI action prompts with its amount/destination/reason and asks for a current code.
- Operations password changes require a fresh, one-use 30-second portal permit. Passwords are not included in source.
- Recovery tickets with private SHA-256-hashed tracking tokens, generic account-neutral creation, per-email submission throttling, role-checked answers and audit.
- Company shipping configuration, seller-specific commissions, saved order shipping charges and commission snapshots.
- Seller inventory editing; price changes return to review; existing order prices stay unchanged.
- Unpaid order cancellation with idempotent stock restoration; audited sequential fulfillment.
- Member search, exact server reconciliation report, and paginated CSV/JSON exports.
- Owner-approved offline Premium purchase with saved pricing, genuine payment reference, operator verification note, MFA, existing company wallet stock, atomic MIO purchase and Premium activation, and retry protection.
- The tested financial corrections in migrations 010/011 have been applied. Migrations 012–018 add the above functionality.

## Test coverage

Includes transfer eligibility, precision, permissions/default function grants, request retries, package points, sponsor attribution, generation limits, PPV cascading, approved-stock order validation, FX snapshots, fair seller rotation, feature ownership/limit, binary carry, chronological cycle validation, exact residual reconciliation, ticket privacy, pending identity restrictions, stale MFA rejection, password permit consumption, shipping/commission history, inventory ownership, cancellation restoration, fulfillment transitions and verified Premium purchase funding.

## Outstanding launch dependencies

The designated operations account is not created yet. The attempted provisioning endpoint was rejected by automatic approval review and was not deployed. Use the safe setup steps in SETUP_GUIDE.md. Company settings and actual inventory remain unset. No live MIO balances were seeded.

Email confirmation/reset delivery requires a configured email service; it has not been tested. Google OAuth is intentionally omitted. Supabase's default SMTP cannot deliver to arbitrary members.

No live hosted Auth/MFA/payment end-to-end or browser/mobile visual test is claimed: this plain static app has no compatible managed browser preview. Source tests do not replace those checks.

Paid refunds/activation reversals, broader package/config management and Phase 2 income methods remain incomplete. Their rules must be resolved before implementation. General financial operation is not declared launch-ready until the initial account, email service and genuine business settings are configured and live flows are exercised.

## 2 October update

The operations and Abdul Rehman accounts exist and are confirmed. Previous account-setup dependency is resolved. The pre-release wallet and ledger totals both reconcile to 100,000 MIO. New migrations preserve balances and place Abdul Rehman as the binary root outside company placement. Current validation: **142 passing checks** (111 database, 31 interface). See NETWORK_RULES.md for current rules and remaining verification limits.

## Seller controls and Allure Care update — 2 October 2026

132 isolated PostgreSQL checks and 37 jsdom interaction checks pass. New coverage includes accepted vendor contracts, multiple company brands, commission-free company purchases, 30% pool / six exact recipients, buyer discount, immutable order snapshots, missing-recipient holds, PKR payment recording, cent rounding, commission RLS, zero PPV, archive controls, founder protection, task navigation, product uploads and private-data clearing. Photos are downloaded from Allure Care's public catalogue and hosted as static assets. Native hosted Auth, actual device uploads against Storage and bank transactions are not end-to-end browser tested; no bank transfer is initiated by this application.

## Sale funding update — 2 October 2026

Current validation:191 checks (150 isolated PostgreSQL/PGlite,41 jsdom). The actual SQL simulation covers a31-member chain, personal PPV upgrades through Advanced2 with no duplicated activation rewards, paid Premium Direct+Generation caps, confirmed-sale funding reconciliation, repeat confirmations, budget-guard rejection, RLS, six prices from0.01 to100, and weekly binary shopping reserves. All local records roll back. Future source payout limits are55% Direct+Generation,35% binary and10% single line; nominal payouts scale proportionally when necessary. Live checks must retain historical wallets/orders and preserve existing manual product approvals. No live bank payment, hosted Auth or browser upload verification is claimed.

Live migration verification:28 Allure positive prices match formula PPV,3 zero-price bundles remain unset, all31 stock counts stay300. Existing product approval states are preserved. No live orders/reward events were created; wallet and ledger sums both remain99,450MIO. Security advisors identify the pre-existing intentional public referral/recovery RPCs and role-checked authenticated RPCs ([function-exposure guidance](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)); leaked-password detection remains a pre-existing Auth setting ([guidance](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)). New reward-event RLS and helper privileges have no new advisor finding.
