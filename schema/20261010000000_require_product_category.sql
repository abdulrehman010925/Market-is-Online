-- Products always belong to a named marketplace category.
-- Existing live rows were checked and contain no null or blank categories.
alter table public.products alter column category set not null;
alter table public.products add constraint products_category_nonblank
  check (length(btrim(category)) >= 2);
