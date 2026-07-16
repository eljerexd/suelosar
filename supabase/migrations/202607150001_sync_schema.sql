-- SuelosAR Phase 3: authenticated, offline-first synchronization tables.
-- Client-side deletes are represented by deleted_at tombstones.

create or replace function public.keep_newest_sync_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.updated_at < old.updated_at then
    return old;
  end if;
  new.owner_id := old.owner_id;
  return new;
end;
$$;

create table if not exists public.markers (
  uuid uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_uuid uuid not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  sync_state text not null check (sync_state in ('local', 'pendingUpload', 'synced', 'conflict')),
  payload jsonb not null
);

create table if not exists public.measurements (
  uuid uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_uuid uuid not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  sync_state text not null check (sync_state in ('local', 'pendingUpload', 'synced', 'conflict')),
  payload jsonb not null
);

create table if not exists public.favorites (
  uuid uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_uuid uuid not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  sync_state text not null check (sync_state in ('local', 'pendingUpload', 'synced', 'conflict')),
  payload jsonb not null
);

create table if not exists public.settings (
  uuid uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_uuid uuid not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  sync_state text not null check (sync_state in ('local', 'pendingUpload', 'synced', 'conflict')),
  payload jsonb not null
);

do $$
declare
  table_name text;
begin
  foreach table_name in array array['markers', 'measurements', 'favorites', 'settings']
  loop
    execute format(
      'create index if not exists %I on public.%I (owner_id, updated_at, uuid)',
      table_name || '_owner_updated_idx',
      table_name
    );
    execute format('alter table public.%I enable row level security', table_name);
    execute format('revoke all on table public.%I from anon', table_name);
    execute format(
      'grant select, insert, update on table public.%I to authenticated',
      table_name
    );
    execute format(
      'drop trigger if exists %I on public.%I',
      table_name || '_keep_newest',
      table_name
    );
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.keep_newest_sync_version()',
      table_name || '_keep_newest',
      table_name
    );
    execute format('drop policy if exists %I on public.%I', table_name || '_select_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_insert_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_update_own', table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select auth.uid()) = owner_id)',
      table_name || '_select_own',
      table_name
    );
    execute format(
      'create policy %I on public.%I for insert to authenticated with check ((select auth.uid()) = owner_id)',
      table_name || '_insert_own',
      table_name
    );
    execute format(
      'create policy %I on public.%I for update to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id)',
      table_name || '_update_own',
      table_name
    );
  end loop;
end;
$$;
