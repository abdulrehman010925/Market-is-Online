# Market is Online: simple setup

Google sign-in has been omitted at your request. Normal email/password login, authenticator codes, and recovery tickets are the selected account flows. No paid services have been added.

## Existing operations account

The designated operations and Abdul Rehman Abbasi accounts already exist and are confirmed. Sign in with existing credentials; this release creates no privileged account or password. Company has one direct founder and no binary position. Abdul Rehman is the member binary root.

Mint/burn, company transfers, Premium payment review and seller withdrawal decisions retain authenticator verification.

## Company settings

In Workspace, supply:

- Your genuine PKR-per-USD conversion rate and its source.
- Shipping charge per order and delivery coverage/policy. Zero is allowed if the company deliberately offers free shipping.
- A separate commission percentage for each approved seller, including the company store.
- Approved public business payment instructions for offline Premium purchases. Do not enter passwords or other secrets here.
- Actual company contact details, product inventory, and approved customer terms.

Checkout stays blocked until shipping, conversion and the relevant seller's commission are configured. Offline Premium purchases stay blocked until payment instructions and conversion are configured.

## First Premium purchase

A member joins using a valid referral code and submits genuine payment-provider/reference details. The request saves the 550 MIO price and PKR conversion rate. The company independently verifies receipt of the exact payment, records a verification note, and approves with a current authenticator code.

Approval atomically debits 550 MIO from the company's existing wallet stock, records the member's purchase, and spends those purchased MIO on Premium activation. It does not mint into the member wallet or relax ordinary transfer rules. A repeated approval cannot duplicate stock debit, activation or bonuses. The company must first have sufficient MIO in its own wallet. No live test balances have been created.

## Email delivery

Password login and TOTP do not require Google OAuth configuration. New email account confirmation and email password reset still require a working Supabase email service. The default Supabase email service is restricted to project team addresses and is unsuitable for general member delivery.

If email confirmation/reset is not configured, recovery tickets remain available but cannot independently prove ownership or reset a password. A ticket holder saves the ticket number and private tracking key and reads replies on the recovery page. Never approve account recovery solely because someone knows a ticket number or email address.

No email verification has been disabled. If you cannot configure email delivery, tell me before inviting members; do not treat email signup or reset delivery as verified.

## Remaining business decisions

Refunds/clawbacks after paid orders, paid activation reversal, fiat withdrawal/settlement, broader package/config editing, and Phase 2 methods still need defined rules and further implementation. Unpaid early orders can be cancelled and their stock is restored exactly once. Fulfillment progresses through confirmed, processing, shipped and delivered.

JSON/CSV exports and a ledger reconciliation report are available in Workspace. Use JSON for exact migration records. No paid backup service or paid database branch was created. Free services still have usage limits.

## Verification limits

142 automated checks pass: 111 isolated PostgreSQL/PGlite checks and 31 jsdom interface checks. Local fixtures are rolled back. Hosted sign-in, email delivery, real payment verification, authenticator enrollment and visual/mobile browser testing are not claimed as completed.

Official references:
- https://supabase.com/docs/guides/auth/auth-mfa/totp
- https://supabase.com/docs/guides/auth/auth-smtp
