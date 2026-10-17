# Vercel deployment

This is a static frontend. The deployable files are in `dist/`.

## Dashboard method

1. Upload/import this source ZIP into a Git repository or Vercel project.
2. Set the project root to the source root.
3. Set **Build Command** to empty/None.
4. Set **Output Directory** to `dist`.
5. Deploy.

## CLI method

```bash
npm install -g vercel
vercel login
vercel --prod
```

When Vercel asks for the output directory, use `dist`. No `node_modules` is required in the ZIP; Vercel can install dependencies if tests/build tooling is needed.

## Supabase after deployment

Keep the existing Supabase URL and publishable key for the same project. If a new project is used, set the new values with:

```bash
MIO_SUPABASE_URL="https://NEW_PROJECT_REF.supabase.co" \
MIO_SUPABASE_PUBLISHABLE_KEY="NEW_PUBLISHABLE_KEY" \
node handover/configure-supabase.mjs
```

Never expose `service_role` or database passwords in Vercel frontend environment variables.
