# Market is Online — current rules and database framework

Updated 2 October 2026 from recovered project instructions, supplied plans, screenshots of the latest prompt and the founder clarification. Later user instructions override older PDF defaults.

## Foundation

Company operations has one permanent direct founder: Abdul Rehman Abbasi. Company has no binary position or left/right referral links. Abdul Rehman retains company as sponsor and is the member binary root. A private registry binds the existing IDs; database guards reject another company direct referral, company binary placement or a parent above the founder. Existing accounts, balances and financial history remain intact.

## Network and referrals

| View | Relationship | Purpose |
| --- | --- | --- |
| Generation | Permanent sponsor edges | Direct and generation earnings |
| Binary | Placement parent and LEFT/RIGHT | Pair volume and placement ancestry |
| Binary pool points | Same binary positions, package BP and available left/right BP | Shares and carry-forward |
| Single-line income | Binary placement uplines | Package-qualified income, max 30 levels |
| Vendor | One level of referred vendor owners | Direct seller network |

Member referral codes gain `-L` and `-R` variants. Side-code signup follows that side exclusively to its first empty position; the inviter remains sponsor. Placement is serialized with a transaction lock and unique parent/side constraint. New screens require side codes. Legacy base codes remain compatible with older clients and use assisted placement. Existing placements are not silently moved.

Tree screens show 2–6 levels, support authorised subtree drill-down and expose names/codes/points without contact details.

## Current funding rules — 2 October 2026

Latest sale-based instructions supersede the earlier commission-pool percentages and the company zero-commission exemption.

- Each vendor has its own agreed commission and sale_distribution. Select the vendor first in Commission & payouts. Company is fixed at 5% of discounted merchandise sale. Shipping and list-price savings are excluded.
- The eight sale percentages (company, buyer discount, affiliate, two uplines, vendor introducer, network budget, unallocated) must total the vendor agreement, not 100% of commission. At sale PKR100 / agreement34%, company receives5, other allocations29, vendor proceeds66.
- External proposals remain20%. Agreements cannot be below5%. Changing an agreed rate holds its remaining budget until the admin saves a vendor distribution. Existing order snapshots and settled history remain intact.
- Company brands have the same funding controls, while customers see ordinary stores. New company brands default to5% company retention. Allure Care uses30% funding: company5%, shopping network25%, other categories0.
- Buyer discount is applied once at checkout. Company is rounded independently to cents; buyer discount cannot exceed the remaining commission cents. Cumulative allocation of the remaining shares reconciles exactly to the snapshotted commission. Missing affiliate recipients remain held. Unallocated funds cannot be manually released as affiliate earnings; network reserves cannot be paid again as cash allocations.

## Allure Care products

Actual discounted source sale prices remain unchanged; compare-at savings are displayed to all shoppers. Existing manual approvals are preserved; formula assignment does not approve listings. The28 positive prices get formula PPV automatically; the3 source bundles priced0 remain blocked with PPV unset. Missing genuine photos remain approval blockers. Stock stays300, and new/manual stock entry remains at least200; sales may deplete it.

Company share = sale price ×5%. Network budget = sale price ×25%. Fixed shopping conversion is PKR300 per point, independent of Premium purchase currency quotes. PPV = (sale price ×25% ÷300) ×90%, truncated to4 decimals. For1595: company79.75, network398.75, PPV1.1962. Price edits recalculate Allure PPV; approval is still manual. This formula's10% deduction reduces personal PPV; it is not another cash company fee.

## Shopping points and funded bonuses

Payment confirmation creates one shopping_reward_events record per order, funded only by snapshotted network allocations. BV = network funding PKR ÷300, truncated to4 decimals; DP equalsBV, GP/BRP are halfBV, and halfBV BP flows through the binary ancestry on the correct side. DP is the defined Direct Points field; a separate DV cash conversion is not defined by the supplied plan.

PPV belongs to the buyer for package activation and never forms the monetary bonus base. Basic1 through Advanced2 retain the approved PPV threshold model; Premium remains explicit550MIO. Shopping activation grants package eligibility without generating another PPV/BV/DP/GP/BP/BRP event or activation bonus. This removes the previous synthetic-PPV cascading and double-funding path.

Sponsor Direct / Generation rewards use shopping BV. Generation1 never stacks with Direct. Source buyer package direct rate applies (Basic1 default for unactivated buyers), followed by5% Gen2–10 subject to each recipient's package depth and active status. Nominal Direct+Generation can reach75% with a Premium chain. Existing binary35% and single-line10% would otherwise make total120% of BV.

New Direct+Generation payouts share a55% BV ceiling; when qualified nominal claims exceed55%, they are reduced proportionally, with each payout truncated to4 decimals. Binary reserves35%, single-line uses at most10% across30 placement levels with package limits10/15/20/25/30. Unqualified/unallocated amounts stay unspent and are not reassigned. BV/DP/GP/BP/BRP are indicators or bonus bases; they are not independently withdrawable cash balances.

Funded shopping bonuses credit the existing MIO wallet and immutable bonus/MIO ledgers. Existing MIO trading and transfer controls continue. Cash affiliate allocations remain PKR, separate from network MIO; recording a bank payment does not initiate a transfer. Shopping bonus valuation is snapshotted at PKR300 per MIO; no new automatic bank cashout is introduced.

## Paid packages and weekly binary

Package tiers remain base10/20/50/100/500, fee1/2/5/10/50, payable/PPV11/22/55/110/550; BV/DP equal base and GP/BP/BRP half base. Existing paid balances and bonuses are not recalculated.

New paid-package Direct+Generation payouts have the same55% funding cap, preserving35% binary and10% single-line. Funded base cannot exceed package BV, base value or payable minus company fee. Locked source guards reject bonus inserts above method/source caps even if configuration later changes.

Weekly binary includes paid-package funded bases plus the exact shopping35% reserves. PPV activation package values are excluded. Full shares still need50BP per side; unmatched BP carries forward. Chronological, non-overlapping cycles and deterministic largest-remainder allocation reconcile member payouts plus company retention exactly to the pool. Zero-share cycles remain recorded as unallocated; no new carry policy is invented.

## Admin, accounting and security

Vendor-wise company earnings show confirmed-sale company allocations only. Shopping package activation fees are excluded from company cash-fee reports because no such payment was received. Prices, rates, PPV and sale distributions are snapshotted per item. Source-order references identify shopping bonuses; immutable keys prevent repeat credits.

Seller proceeds remain gross minus agreed commission in the PKR income ledger. Withdrawals reserve funds, reject to release, and require verified actual payment references to mark paid. Existing seller onboarding, photo upload, listing review, six featured company products, member/founder protection and authenticator controls remain.

New reward-event data is RLS-protected for its buyer/admin and read-only to clients. Calculation helpers are private, security-definer functions have fixed empty search_path, and financial credits run atomically on the server. Vendor distribution saves require admin role and recent authenticator verification.

## Verification

191 passing checks:150 isolated PostgreSQL/PGlite and41 jsdom interactions. Simulations run actual order, point, activation, bonus, wallet and binary routines: full sponsor/placement chains, PPV activation, double confirmations, source-budget rejection, RLS, vendor-specific snapshots, and six tiny/normal-price rounding cases. No test payments, wallets or sales are posted to the live database. Live verification found28 formula matches and3 source-price-zero bundles with PPV unset; all31 stock counts remain300. Wallet and ledger sums both remain99,450MIO. Hosted Auth/MFA, actual mobile photo upload and bank transfers are not browser end-to-end verified. Delivery settings and genuine payment verification remain business setup requirements.

Earlier SQL migrations preserve the historical rules and audit trail; this document and the latest migration define future events.

## DRAFT: Free affiliates and held first-level earnings — not applied

Automatic approval review rejected production financial migration. Tested implementation is in drafts/held-first-level-rewards.sql and drafts/held-affiliate-app.js. Only the featured-products bounded replacement is live.

### Requested rules
Completed free registration stays inactive but may share affiliate selling links and LEFT/RIGHT referral codes. Inactive members receive only first-level direct incentives at BASIC_1 direct rate and the selling-affiliate allocation chosen independently for each vendor. Generation, binary, single-line and affiliate-upline shares still require an approved package. Own purchases never pay self-commission.

Pending direct MIO and identified affiliate PKR allocations reserve their original source funding without crediting spendable income. Held reward BV equals direct MIO, or affiliate commission PKR divided by 300; held reward PPV is 90% of that BV, truncated to four decimals. These are informational/non-cash reward points and do not generate an additional bonus liability. Held points do not count towards initial activation; own shopping PPV or a verified package payment activates the account. Approval releases reserved income and reward points exactly once. Affiliate commission remains PKR and is never automatically converted to MIO. Withdrawal/payment marking stays blocked until package eligibility.

Vendor rates are not invented: existing affiliate percentages remain unchanged, including current Allure Care affiliate 0% until admin assigns a share from its total agreed sale allocation. Company remains 5%; affiliate and all other allocations must reconcile to the agreed vendor commission.
