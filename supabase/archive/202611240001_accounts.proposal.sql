-- Additive foundation for a future recipe sync. Nothing here imports guest records.
begin;
create table public.crumb_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.crumb_profiles enable row level security;
create policy "Own profile" on public.crumb_profiles for all to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create table public.crumb_menu_books (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (length(trim(title)) between 1 and 200),
  created_at timestamptz not null default now(),
  unique(id, owner_id)
);
alter table public.crumb_menu_books enable row level security;
create policy "Own books" on public.crumb_menu_books for all to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);

create table public.crumb_recipes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  book_id uuid,
  title text not null default '',
  recipe jsonb not null default '{}'::jsonb,
  photo_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (book_id, owner_id) references public.crumb_menu_books(id, owner_id)
);
alter table public.crumb_recipes enable row level security;
create policy "Own recipes" on public.crumb_recipes for all to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create index crumb_recipes_owner on public.crumb_recipes(owner_id);
create index crumb_menu_books_owner on public.crumb_menu_books(owner_id);
revoke all on public.crumb_profiles, public.crumb_menu_books, public.crumb_recipes from anon;
grant select, insert, update, delete on public.crumb_profiles, public.crumb_menu_books, public.crumb_recipes to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('crumb-photos', 'crumb-photos', false, 20971520, array['image/jpeg', 'image/png', 'image/heic']);
create policy "Own recipe photos" on storage.objects for all to authenticated
  using (bucket_id = 'crumb-photos' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'crumb-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
commit;
