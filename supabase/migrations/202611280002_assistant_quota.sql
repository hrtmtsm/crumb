-- Server-only budget controls. No Plus check: Ask Crumb is available on the free plan.
create table if not exists public.crumb_ai_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null default current_date,
  requests integer not null default 0,
  images integer not null default 0,
  primary key (user_id, day)
);
alter table public.crumb_ai_usage enable row level security;
revoke all on public.crumb_ai_usage from anon, authenticated;
create or replace function public.crumb_take_ai_quota(p_user uuid, p_image boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare accepted boolean;
begin
  insert into public.crumb_ai_usage (user_id,day,requests,images)
  values(p_user,current_date,case when p_image then 0 else 1 end,case when p_image then 1 else 0 end)
  on conflict (user_id,day) do update set
    requests=crumb_ai_usage.requests + case when p_image then 0 else 1 end,
    images=crumb_ai_usage.images + case when p_image then 1 else 0 end
  where (not p_image and crumb_ai_usage.requests < 100) or (p_image and crumb_ai_usage.images < 12)
  returning true into accepted;
  return coalesce(accepted,false);
end $$;
revoke all on function public.crumb_take_ai_quota(uuid,boolean) from public, anon, authenticated;
grant execute on function public.crumb_take_ai_quota(uuid,boolean) to service_role;
