# Market is Online — developer map

This is a buildless static frontend backed by Supabase.

## Where to edit

- `dist/index.html` — page structure, forms, navigation and semantic markup.
- `dist/styles.css` — all visual styling, responsive breakpoints and image/card layout.
- `dist/app.js` — browser interactions, Supabase reads/RPC calls and rendering.
- `schema/` — database migrations and business rules. Keep formulas here; do not duplicate payout logic in the UI.
- `tests/` — database and interface checks.
- `imports/` — catalogue/source data only.
- `dist/assets/` — committed static campaign, category and optimized image assets.
- `.openai/hosting.json` — Sites deployment identity; do not replace the project id.

## Safe change rule

Business rules belong in `schema/` and Supabase RPCs. Frontend code should only display returned values and collect user input. After schema changes, apply the migration to Supabase, run the relevant test, then publish the exact Git commit.

## Image performance

Product PNGs have WebP companions where possible. `productImageMarkup()` emits a WebP `<source>` first and keeps the original URL as a fallback. New product uploads remain compatible without a data migration.

## Deployment

This is a plain `dist/` site. Run `node --check dist/app.js`, `git diff --check`, commit, push `main`, then save and deploy the matching Sites version. Never package a dirty working tree.
