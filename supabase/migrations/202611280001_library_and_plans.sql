-- Self-contained schema for the production implementation. The earlier 20261124 SQL was an un-applied proposal.
-- No public data, client-set plan flags, service keys, or auto-import of guest photos.
begin;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create table public.crumb_plan_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  valid_until timestamptz not null,
  revoked boolean not null default false,
  event_at timestamptz not null,
  original_transaction_id text,
  source text not null check (source in ('apple','beta'))
);
create unique index crumb_store_original on public.crumb_plan_access(original_transaction_id) where original_transaction_id is not null;
alter table public.crumb_plan_access enable row level security;
create policy "Own plan read" on public.crumb_plan_access for select to authenticated using (user_id=(select auth.uid()));
revoke all on public.crumb_plan_access from anon, authenticated;
grant select on public.crumb_plan_access to authenticated;

create function public.crumb_has_plus(p_user uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.crumb_plan_access where user_id=p_user and not revoked and valid_until>now());
$$;
create function public.crumb_my_plan() returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('active',public.crumb_has_plus(auth.uid()),'expires_at',
    (select extract(epoch from valid_until) from public.crumb_plan_access where user_id=auth.uid()));
$$;

create table public.crumb_books (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
 client_key text not null, title text not null check(length(trim(title)) between 1 and 200),
 snapshot jsonb not null default '{"recipes":[]}'::jsonb,
 revision bigint not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(owner_id,client_key), check(jsonb_typeof(snapshot)='object')
);
create table public.crumb_book_members (
 book_id uuid not null references public.crumb_books(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 joined_at timestamptz not null default now(), primary key(book_id,user_id)
);
create table public.crumb_book_invites (
 id uuid primary key default gen_random_uuid(), book_id uuid not null references public.crumb_books(id) on delete cascade,
 token_hash text not null unique, expires_at timestamptz not null default now()+interval '7 days',
 accepted_by uuid references auth.users(id) on delete set null, accepted_at timestamptz,
 created_at timestamptz not null default now()
);
create index crumb_member_user on public.crumb_book_members(user_id);
create index crumb_book_owner on public.crumb_books(owner_id);
alter table public.crumb_books enable row level security;
alter table public.crumb_book_members enable row level security;
alter table public.crumb_book_invites enable row level security;
revoke all on public.crumb_books, public.crumb_book_members, public.crumb_book_invites from anon, authenticated;

create function public.crumb_can_read_book(p_book uuid) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.crumb_books b where b.id=p_book and
 (b.owner_id=auth.uid() or exists(select 1 from public.crumb_book_members m where m.book_id=b.id and m.user_id=auth.uid())));
$$;
create function public.crumb_can_write_book(p_book uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.crumb_can_read_book(p_book) and exists(select 1 from public.crumb_books b where b.id=p_book and public.crumb_has_plus(b.owner_id));
$$;
create policy "Books readable by owner and invited members" on public.crumb_books for select to authenticated using(public.crumb_can_read_book(id));
grant select on public.crumb_books to authenticated;

create function public.crumb_list_books() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'owner_id',b.owner_id,'client_key',b.client_key,'title',b.title,
 'snapshot',b.snapshot,'revision',b.revision,'owner_plus',public.crumb_has_plus(b.owner_id)) order by b.created_at), '[]'::jsonb)
 from public.crumb_books b where public.crumb_can_read_book(b.id);
$$;
create function public.crumb_create_book(p_client_key text, p_title text) returns jsonb language plpgsql security definer set search_path='' as $$
 declare b public.crumb_books;
 begin
 if auth.uid() is null then raise insufficient_privilege; end if;
 if length(p_client_key) not between 1 and 100 or length(trim(p_title)) not between 1 and 200 then raise exception 'invalid book'; end if;
 select * into b from public.crumb_books where owner_id=auth.uid() and client_key=p_client_key;
 if found then return to_jsonb(b)||jsonb_build_object('owner_plus',public.crumb_has_plus(b.owner_id)); end if;
 if p_client_key<>'default' and not public.crumb_has_plus(auth.uid()) then raise insufficient_privilege using message='Plus required'; end if;
 insert into public.crumb_books(owner_id,client_key,title) values(auth.uid(),p_client_key,trim(p_title))
 on conflict(owner_id,client_key) do update set title=public.crumb_books.title returning * into b;
 return to_jsonb(b)||jsonb_build_object('owner_plus',public.crumb_has_plus(b.owner_id));
 end;
$$;
create function public.crumb_save_book(p_id uuid, p_revision bigint, p_snapshot jsonb) returns bigint language plpgsql security definer set search_path='' as $$
 declare v_revision bigint;
 begin
 if not public.crumb_can_write_book(p_id) then raise insufficient_privilege; end if;
 if jsonb_typeof(p_snapshot) is distinct from 'object' or jsonb_typeof(p_snapshot->'recipes') is distinct from 'array'
 or length(p_snapshot::text)>8388608 then raise exception 'invalid snapshot'; end if;
 update public.crumb_books set snapshot=p_snapshot, revision=revision+1, updated_at=now()
 where id=p_id and revision=p_revision returning revision into v_revision;
 if not found then raise sqlstate 'PT409' using message='revision conflict'; end if;
 return v_revision;
 end;
$$;
create function public.crumb_save_library(p_books jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
 declare item jsonb; current_revision bigint; result jsonb='{}'::jsonb; new_revision bigint;
 begin
 if auth.uid() is null or jsonb_typeof(p_books)<>'array' or jsonb_array_length(p_books)>1000 then raise insufficient_privilege; end if;
 if (select count(*) from jsonb_array_elements(p_books)) <> (select count(distinct value->>'id') from jsonb_array_elements(p_books)) then raise exception 'duplicate books'; end if;
 for item in select value from jsonb_array_elements(p_books) order by value->>'id' loop
  if not public.crumb_can_write_book((item->>'id')::uuid) then raise insufficient_privilege; end if;
  select revision into current_revision from public.crumb_books where id=(item->>'id')::uuid for update;
  if current_revision<>(item->>'revision')::bigint then raise sqlstate 'PT409' using message='revision conflict'; end if;
  if jsonb_typeof(item->'snapshot') is distinct from 'object' or jsonb_typeof(item->'snapshot'->'recipes') is distinct from 'array' or length((item->'snapshot')::text)>8388608 then raise exception 'invalid snapshot'; end if;
 end loop;
 for item in select value from jsonb_array_elements(p_books) loop
  update public.crumb_books set snapshot=item->'snapshot',revision=revision+1,updated_at=now() where id=(item->>'id')::uuid returning revision into new_revision;
  result=result||jsonb_build_object(item->>'id',new_revision);
 end loop;
 return result;
 end;
$$;
create function public.crumb_create_invite(p_book uuid) returns text language plpgsql security definer set search_path='' as $$
 declare v_token text;
 begin
 if not exists(select 1 from public.crumb_books where id=p_book and owner_id=auth.uid()) or not public.crumb_has_plus(auth.uid()) then raise insufficient_privilege; end if;
 v_token=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.crumb_book_invites(book_id,token_hash) values(p_book,encode(extensions.digest(v_token,'sha256'),'hex'));
 return v_token;
 end;
$$;
create function public.crumb_accept_invite(p_token text) returns uuid language plpgsql security definer set search_path='' as $$
 declare i public.crumb_book_invites; v_owner uuid;
 begin
 if auth.uid() is null or p_token !~ '^[0-9a-f]{64}$' then raise insufficient_privilege; end if;
 select * into i from public.crumb_book_invites where token_hash=encode(extensions.digest(p_token,'sha256'),'hex') for update;
 if not found or i.expires_at<=now() or (i.accepted_at is not null and i.accepted_by is distinct from auth.uid()) then raise sqlstate 'PT404' using message='invite unavailable'; end if;
 select owner_id into v_owner from public.crumb_books where id=i.book_id for update;
 if not public.crumb_has_plus(v_owner) then raise insufficient_privilege using message='Owner Plus expired'; end if;
 if v_owner=auth.uid() then return i.book_id; end if;
 if not exists(select 1 from public.crumb_book_members where book_id=i.book_id and user_id=auth.uid())
 and (select count(*) from public.crumb_book_members where book_id=i.book_id)>=9 then raise exception 'member limit reached'; end if;
 insert into public.crumb_book_members(book_id,user_id) values(i.book_id,auth.uid()) on conflict do nothing;
 update public.crumb_book_invites set accepted_by=auth.uid(),accepted_at=coalesce(accepted_at,now()) where id=i.id;
 return i.book_id;
 end;
$$;
create function public.crumb_remove_member(p_book uuid,p_member uuid) returns void language plpgsql security definer set search_path='' as $$
 begin
 if not exists(select 1 from public.crumb_books where id=p_book and owner_id=auth.uid()) and p_member is distinct from auth.uid() then raise insufficient_privilege; end if;
 delete from public.crumb_book_members where book_id=p_book and user_id=p_member;
 end;
$$;
create function public.crumb_revoke_invites(p_book uuid) returns void language plpgsql security definer set search_path='' as $$
 begin
 if not exists(select 1 from public.crumb_books where id=p_book and owner_id=auth.uid()) then raise insufficient_privilege; end if;
 delete from public.crumb_book_invites where book_id=p_book and accepted_at is null;
 end;
$$;

create table public.crumb_account_state (
 user_id uuid primary key references auth.users(id) on delete cascade,
 payload jsonb not null default '{}'::jsonb, revision bigint not null default 1
);
alter table public.crumb_account_state enable row level security;
revoke all on public.crumb_account_state from anon, authenticated;
create function public.crumb_get_account_state() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce((select jsonb_build_object('payload',payload,'revision',revision) from public.crumb_account_state where user_id=auth.uid()),'null'::jsonb);
$$;
create function public.crumb_save_account_state(p_payload jsonb,p_revision bigint) returns bigint language plpgsql security definer set search_path='' as $$
 declare v_revision bigint;
 begin
 if auth.uid() is null or not public.crumb_has_plus(auth.uid()) then raise insufficient_privilege; end if;
 if length(p_payload::text)>8388608 then raise exception 'invalid state'; end if;
 if p_revision=0 then
  insert into public.crumb_account_state(user_id,payload) values(auth.uid(),p_payload) on conflict do nothing returning revision into v_revision;
 else
  update public.crumb_account_state set payload=p_payload,revision=revision+1 where user_id=auth.uid() and revision=p_revision returning revision into v_revision;
 end if;
 if v_revision is null then raise sqlstate 'PT409' using message='state revision conflict'; end if;
 return v_revision;
 end;
$$;

-- Apple signature verification happens in an Edge Function. Authenticated clients cannot execute this grant function.
create function public.crumb_apply_store_event(p_user uuid,p_expires timestamptz,p_revoked boolean,p_event_at timestamptz,p_original text)
 returns void language plpgsql security definer set search_path='' as $$
 begin
 if p_event_at>now()+interval '5 minutes' then raise exception 'invalid timestamp'; end if;
 if exists(select 1 from public.crumb_plan_access where original_transaction_id=p_original and user_id<>p_user) then raise insufficient_privilege; end if;
 insert into public.crumb_plan_access(user_id,valid_until,revoked,event_at,original_transaction_id,source)
 values(p_user,p_expires,p_revoked,p_event_at,p_original,'apple')
 on conflict(user_id) do update set valid_until=excluded.valid_until,revoked=excluded.revoked,event_at=excluded.event_at,
 original_transaction_id=excluded.original_transaction_id,source='apple'
 where public.crumb_plan_access.event_at<excluded.event_at;
 end;
$$;

-- Files are immutable content-addressed objects. Private profile/plate images use u/<owner>/..., recipes b/<book>/....
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('crumb-photos','crumb-photos',false,20971520,array['image/jpeg','image/png','image/heic','application/octet-stream'])
 on conflict(id) do nothing;
do $$ begin if exists(select 1 from storage.buckets where id='crumb-photos' and public) then raise exception 'crumb-photos must be private'; end if; end $$;
create function public.crumb_storage_access(p_name text,p_write boolean) returns boolean language plpgsql stable security definer set search_path='' as $$
 declare parts text[]; target uuid;
 begin
 parts=string_to_array(p_name,'/');
 if parts[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
 target=parts[2]::uuid;
 if parts[1]='u' then return auth.uid()=target and (not p_write or public.crumb_has_plus(target)); end if;
 if parts[1]='b' then
  if p_write then return public.crumb_can_write_book(target); else return public.crumb_can_read_book(target); end if;
 end if;
 return false;
 end;
$$;
create policy "Crumb private objects read" on storage.objects for select to authenticated using(bucket_id='crumb-photos' and public.crumb_storage_access(name,false));
create policy "Crumb private objects insert" on storage.objects for insert to authenticated with check(bucket_id='crumb-photos' and public.crumb_storage_access(name,true));
-- No client update/delete: prevents replacing another collaborator's image or deleting history before a conflict is resolved.

revoke all on function public.crumb_has_plus(uuid),public.crumb_my_plan(),public.crumb_can_read_book(uuid),public.crumb_can_write_book(uuid),
 public.crumb_list_books(),public.crumb_create_book(text,text),public.crumb_save_book(uuid,bigint,jsonb),public.crumb_save_library(jsonb),public.crumb_create_invite(uuid),
 public.crumb_accept_invite(text),public.crumb_remove_member(uuid,uuid),public.crumb_revoke_invites(uuid),public.crumb_get_account_state(),
 public.crumb_save_account_state(jsonb,bigint),public.crumb_storage_access(text,boolean),public.crumb_apply_store_event(uuid,timestamptz,boolean,timestamptz,text)
 from public,anon,authenticated;
grant execute on function public.crumb_my_plan(),public.crumb_can_read_book(uuid),public.crumb_can_write_book(uuid),public.crumb_list_books(),
 public.crumb_create_book(text,text),public.crumb_save_book(uuid,bigint,jsonb),public.crumb_save_library(jsonb),public.crumb_create_invite(uuid),public.crumb_accept_invite(text),
 public.crumb_remove_member(uuid,uuid),public.crumb_revoke_invites(uuid),public.crumb_get_account_state(),public.crumb_save_account_state(jsonb,bigint),public.crumb_storage_access(text,boolean)
 to authenticated;
grant execute on function public.crumb_apply_store_event(uuid,timestamptz,boolean,timestamptz,text) to service_role;
commit;
