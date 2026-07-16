-- SuelosAR Phase 5: secure, accountless device pairing for authenticated
-- anonymous Supabase sessions. Pairing secrets are one-use and short-lived.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron with schema extensions;

create table public.sync_groups (
  group_uuid uuid primary key default gen_random_uuid(),
  owner_device_uuid uuid not null,
  created_at timestamptz not null default now()
);

create table public.paired_devices (
  device_uuid uuid primary key,
  group_uuid uuid not null references public.sync_groups(group_uuid) on delete cascade,
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  device_name text not null check (char_length(device_name) between 1 and 80),
  name_is_custom boolean not null default false,
  platform text not null check (char_length(platform) between 1 and 40),
  paired_at timestamptz not null default now(),
  last_sync_at timestamptz,
  removed_at timestamptz
);

create index paired_devices_group_idx
  on public.paired_devices (group_uuid, removed_at, paired_at);

create table public.pairing_tokens (
  token_hash bytea primary key,
  pairing_code text not null unique check (pairing_code ~ '^[0-9]{6}$'),
  group_uuid uuid not null references public.sync_groups(group_uuid) on delete cascade,
  creator_device_uuid uuid not null references public.paired_devices(device_uuid) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_by_device_uuid uuid
);

create index pairing_tokens_expiry_idx on public.pairing_tokens (expires_at);

create table public.pairing_attempts (
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index pairing_attempts_user_time_idx
  on public.pairing_attempts (auth_user_id, attempted_at);

alter table public.sync_groups enable row level security;
alter table public.paired_devices enable row level security;
alter table public.pairing_tokens enable row level security;
alter table public.pairing_attempts enable row level security;

revoke all on public.sync_groups from anon, authenticated;
revoke all on public.paired_devices from anon, authenticated;
revoke all on public.pairing_tokens from anon, authenticated;
revoke all on public.pairing_attempts from anon, authenticated;

create or replace function public.register_new_sync_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device_uuid uuid;
  v_group_uuid uuid;
begin
  begin
    v_device_uuid := (new.raw_user_meta_data ->> 'device_uuid')::uuid;
  exception when others then
    return new;
  end;
  if exists (select 1 from public.paired_devices where device_uuid = v_device_uuid) then
    return new;
  end if;
  insert into public.sync_groups (owner_device_uuid)
  values (v_device_uuid)
  returning group_uuid into v_group_uuid;
  insert into public.paired_devices (
    device_uuid, group_uuid, auth_user_id, device_name, platform
  ) values (
    v_device_uuid, v_group_uuid, new.id, 'Dispositivo', 'Desconocido'
  );
  return new;
end;
$$;

revoke all on function public.register_new_sync_auth_user() from public;
drop trigger if exists on_sync_auth_user_created on auth.users;
create trigger on_sync_auth_user_created
after insert on auth.users
for each row execute function public.register_new_sync_auth_user();

-- Backfill anonymous sessions created by Phase 3 before this migration.
do $$
declare
  existing_user auth.users%rowtype;
  existing_device_uuid uuid;
  created_group_uuid uuid;
begin
  for existing_user in
    select * from auth.users u
    where u.raw_user_meta_data ? 'device_uuid'
  loop
    begin
      existing_device_uuid :=
        (existing_user.raw_user_meta_data ->> 'device_uuid')::uuid;
    exception when others then
      continue;
    end;
    if not exists (
      select 1 from public.paired_devices
      where device_uuid = existing_device_uuid
    ) then
      insert into public.sync_groups (owner_device_uuid)
      values (existing_device_uuid)
      returning group_uuid into created_group_uuid;
      insert into public.paired_devices (
        device_uuid, group_uuid, auth_user_id, device_name, platform
      ) values (
        existing_device_uuid, created_group_uuid, existing_user.id,
        'Dispositivo', 'Desconocido'
      );
    end if;
  end loop;
end;
$$;

-- These tables are intentionally RPC-only. RLS remains enabled with no direct
-- policies or grants, so clients cannot inspect or mutate pairing secrets.

create or replace function public.current_sync_group()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select group_uuid
  from public.paired_devices
  where auth_user_id = auth.uid() and removed_at is null
  limit 1;
$$;

revoke all on function public.current_sync_group() from public;
grant execute on function public.current_sync_group() to authenticated;

create or replace function public.cleanup_expired_pairing_tokens()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.pairing_tokens
  where expires_at <= now() or consumed_at is not null;

  delete from public.pairing_attempts
  where attempted_at < now() - interval '10 minutes';
$$;

revoke all on function public.cleanup_expired_pairing_tokens() from public;

select cron.schedule(
  'suelosar-pairing-token-cleanup',
  '*/5 * * * *',
  'select public.cleanup_expired_pairing_tokens()'
);

create or replace function public.pairing_group_payload(
  p_group_uuid uuid,
  p_current_device_uuid uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'group', jsonb_build_object(
      'group_uuid', g.group_uuid,
      'owner_device_uuid', g.owner_device_uuid,
      'created_at', g.created_at
    ),
    'devices', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'device_uuid', d.device_uuid,
          'device_name', d.device_name,
          'platform', d.platform,
          'paired_at', d.paired_at,
          'last_sync_at', d.last_sync_at,
          'is_current_device', d.device_uuid = p_current_device_uuid
        ) order by (d.device_uuid = p_current_device_uuid) desc, d.paired_at
      )
      from public.paired_devices d
      where d.group_uuid = g.group_uuid and d.removed_at is null
    ), '[]'::jsonb)
  )
  from public.sync_groups g
  where g.group_uuid = p_group_uuid;
$$;

revoke all on function public.pairing_group_payload(uuid, uuid) from public;

create or replace function public.register_sync_device(
  p_device_uuid uuid,
  p_device_name text,
  p_platform text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_uuid uuid;
  v_existing_auth uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if nullif(trim(p_device_name), '') is null or nullif(trim(p_platform), '') is null then
    raise exception 'invalid device details';
  end if;

  select group_uuid, auth_user_id
    into v_group_uuid, v_existing_auth
  from public.paired_devices
  where device_uuid = p_device_uuid and removed_at is null;

  if v_group_uuid is null then
    insert into public.sync_groups (owner_device_uuid)
    values (p_device_uuid)
    returning group_uuid into v_group_uuid;

    insert into public.paired_devices (
      device_uuid, group_uuid, auth_user_id, device_name, platform
    ) values (
      p_device_uuid, v_group_uuid, auth.uid(), trim(p_device_name), trim(p_platform)
    );
  elsif v_existing_auth <> auth.uid() then
    raise exception 'device identity already registered';
  else
    update public.paired_devices
    set device_name = case
          when name_is_custom then device_name else trim(p_device_name)
        end,
        platform = trim(p_platform)
    where device_uuid = p_device_uuid;
  end if;

  -- Assign pre-pairing records created by this anonymous session to its group.
  update public.markers set group_uuid = v_group_uuid
    where owner_id = auth.uid() and group_uuid is null;
  update public.measurements set group_uuid = v_group_uuid
    where owner_id = auth.uid() and group_uuid is null;
  update public.favorites set group_uuid = v_group_uuid
    where owner_id = auth.uid() and group_uuid is null;
  update public.settings set group_uuid = v_group_uuid
    where owner_id = auth.uid() and group_uuid is null;

  return public.pairing_group_payload(v_group_uuid, p_device_uuid);
end;
$$;

create or replace function public.create_pairing_session(p_device_uuid uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_uuid uuid;
  v_token text;
  v_token_bytes bytea;
  v_code text;
  v_random bytea;
  v_number bigint;
  v_expires_at timestamptz := now() + interval '5 minutes';
begin
  perform public.cleanup_expired_pairing_tokens();

  select group_uuid into v_group_uuid
  from public.paired_devices
  where device_uuid = p_device_uuid
    and auth_user_id = auth.uid()
    and removed_at is null;
  if v_group_uuid is null then raise exception 'device is not registered'; end if;

  v_token_bytes := extensions.gen_random_bytes(32);
  v_token := translate(encode(v_token_bytes, 'base64'), E'+/=\n', '-_');

  loop
    v_random := extensions.gen_random_bytes(4);
    v_number := (
      get_byte(v_random, 0)::bigint * 16777216 +
      get_byte(v_random, 1)::bigint * 65536 +
      get_byte(v_random, 2)::bigint * 256 +
      get_byte(v_random, 3)::bigint
    );
    v_code := lpad(((v_number % 900000) + 100000)::text, 6, '0');
    exit when not exists (
      select 1 from public.pairing_tokens where pairing_code = v_code
    );
  end loop;

  insert into public.pairing_tokens (
    token_hash, pairing_code, group_uuid, creator_device_uuid, expires_at
  ) values (
    extensions.digest(v_token, 'sha256'), v_code, v_group_uuid,
    p_device_uuid, v_expires_at
  );

  return jsonb_build_object(
    'token', v_token,
    'pairing_code', v_code,
    'expires_at', v_expires_at
  );
end;
$$;

create or replace function public.claim_pairing_session(
  p_device_uuid uuid,
  p_device_name text,
  p_platform text,
  p_token text default null,
  p_pairing_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pairing public.pairing_tokens%rowtype;
  v_current_group uuid;
  v_old_group uuid;
  v_other_devices integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  perform public.cleanup_expired_pairing_tokens();

  insert into public.pairing_attempts (auth_user_id) values (auth.uid());
  if (
    select count(*) from public.pairing_attempts
    where auth_user_id = auth.uid()
      and attempted_at > now() - interval '5 minutes'
  ) > 8 then
    return jsonb_build_object('error', 'too_many_attempts');
  end if;

  if nullif(trim(coalesce(p_token, '')), '') is not null then
    select * into v_pairing from public.pairing_tokens
    where token_hash = extensions.digest(trim(p_token), 'sha256')
    for update;
  elsif coalesce(p_pairing_code, '') ~ '^[0-9]{6}$' then
    select * into v_pairing from public.pairing_tokens
    where pairing_code = p_pairing_code
    for update;
  else
    return jsonb_build_object('error', 'invalid_pairing');
  end if;

  if v_pairing.token_hash is null then
    return jsonb_build_object('error', 'invalid_pairing');
  end if;
  if v_pairing.expires_at <= now() then
    delete from public.pairing_tokens where token_hash = v_pairing.token_hash;
    return jsonb_build_object('error', 'pairing_expired');
  end if;
  if v_pairing.consumed_at is not null then
    return jsonb_build_object('error', 'invalid_pairing');
  end if;

  select group_uuid into v_current_group
  from public.paired_devices
  where device_uuid = p_device_uuid
    and auth_user_id = auth.uid()
    and removed_at is null;

  if v_current_group = v_pairing.group_uuid then
    return jsonb_build_object('error', 'already_paired');
  end if;

  if v_current_group is not null then
    select count(*) into v_other_devices
    from public.paired_devices
    where group_uuid = v_current_group
      and device_uuid <> p_device_uuid
      and removed_at is null;
    if v_other_devices > 0 then
      return jsonb_build_object('error', 'already_in_shared_group');
    end if;
    v_old_group := v_current_group;
  end if;

  insert into public.paired_devices (
    device_uuid, group_uuid, auth_user_id, device_name, platform, paired_at
  ) values (
    p_device_uuid, v_pairing.group_uuid, auth.uid(), trim(p_device_name),
    trim(p_platform), now()
  )
  on conflict (device_uuid) do update set
    group_uuid = excluded.group_uuid,
    auth_user_id = excluded.auth_user_id,
    device_name = case
      when public.paired_devices.name_is_custom
        then public.paired_devices.device_name
      else excluded.device_name
    end,
    name_is_custom = public.paired_devices.name_is_custom,
    platform = excluded.platform,
    paired_at = excluded.paired_at,
    removed_at = null;

  update public.markers set group_uuid = v_pairing.group_uuid where owner_id = auth.uid();
  update public.measurements set group_uuid = v_pairing.group_uuid where owner_id = auth.uid();
  update public.favorites set group_uuid = v_pairing.group_uuid where owner_id = auth.uid();
  update public.settings set group_uuid = v_pairing.group_uuid where owner_id = auth.uid();

  update public.pairing_tokens
  set consumed_at = now(), consumed_by_device_uuid = p_device_uuid
  where token_hash = v_pairing.token_hash;

  if v_old_group is not null and v_old_group <> v_pairing.group_uuid then
    delete from public.sync_groups where group_uuid = v_old_group;
  end if;

  return public.pairing_group_payload(v_pairing.group_uuid, p_device_uuid);
end;
$$;

create or replace function public.list_paired_devices(p_device_uuid uuid)
returns table (
  device_uuid uuid,
  device_name text,
  platform text,
  paired_at timestamptz,
  last_sync_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare v_group_uuid uuid;
begin
  perform public.cleanup_expired_pairing_tokens();
  select d.group_uuid into v_group_uuid
  from public.paired_devices d
  where d.device_uuid = p_device_uuid
    and d.auth_user_id = auth.uid()
    and d.removed_at is null;
  if v_group_uuid is null then raise exception 'device is not registered'; end if;
  return query
    select d.device_uuid, d.device_name, d.platform, d.paired_at, d.last_sync_at
    from public.paired_devices d
    where d.group_uuid = v_group_uuid and d.removed_at is null
    order by (d.device_uuid = p_device_uuid) desc, d.paired_at;
end;
$$;

create or replace function public.rename_paired_device(
  p_current_device_uuid uuid,
  p_target_device_uuid uuid,
  p_device_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_group_uuid uuid; v_device public.paired_devices%rowtype;
begin
  if nullif(trim(p_device_name), '') is null then raise exception 'invalid device name'; end if;
  select group_uuid into v_group_uuid from public.paired_devices
  where device_uuid = p_current_device_uuid
    and auth_user_id = auth.uid() and removed_at is null;
  update public.paired_devices
  set device_name = left(trim(p_device_name), 80), name_is_custom = true
  where device_uuid = p_target_device_uuid
    and group_uuid = v_group_uuid and removed_at is null
  returning * into v_device;
  if v_device.device_uuid is null then raise exception 'device not found'; end if;
  return jsonb_build_object(
    'device_uuid', v_device.device_uuid,
    'device_name', v_device.device_name,
    'platform', v_device.platform,
    'paired_at', v_device.paired_at,
    'last_sync_at', v_device.last_sync_at
  );
end;
$$;

create or replace function public.remove_paired_device(
  p_current_device_uuid uuid,
  p_target_device_uuid uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_group_uuid uuid;
begin
  if p_current_device_uuid = p_target_device_uuid then
    raise exception 'cannot remove current device';
  end if;
  select group_uuid into v_group_uuid from public.paired_devices
  where device_uuid = p_current_device_uuid
    and auth_user_id = auth.uid() and removed_at is null;
  if v_group_uuid is null then raise exception 'device is not registered'; end if;
  update public.paired_devices set removed_at = now()
  where device_uuid = p_target_device_uuid
    and group_uuid = v_group_uuid and removed_at is null;
  if not found then raise exception 'device not found'; end if;
end;
$$;

grant execute on function public.register_sync_device(uuid, text, text) to authenticated;
grant execute on function public.create_pairing_session(uuid) to authenticated;
grant execute on function public.claim_pairing_session(uuid, text, text, text, text) to authenticated;
grant execute on function public.list_paired_devices(uuid) to authenticated;
grant execute on function public.rename_paired_device(uuid, uuid, text) to authenticated;
grant execute on function public.remove_paired_device(uuid, uuid) to authenticated;

-- Existing synchronized entities become group-scoped without changing the
-- client adapter. A trigger assigns the authenticated device's group.
alter table public.markers add column if not exists group_uuid uuid references public.sync_groups(group_uuid);
alter table public.measurements add column if not exists group_uuid uuid references public.sync_groups(group_uuid);
alter table public.favorites add column if not exists group_uuid uuid references public.sync_groups(group_uuid);
alter table public.settings add column if not exists group_uuid uuid references public.sync_groups(group_uuid);

create or replace function public.assign_sync_group()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_group_uuid uuid;
begin
  select group_uuid into v_group_uuid from public.paired_devices
  where auth_user_id = auth.uid() and removed_at is null;
  if v_group_uuid is null then raise exception 'device is not paired'; end if;
  if tg_op = 'INSERT' then new.group_uuid := v_group_uuid; end if;
  return new;
end;
$$;

create or replace function public.keep_newest_sync_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.updated_at < old.updated_at then return old; end if;
  new.owner_id := old.owner_id;
  new.group_uuid := old.group_uuid;
  return new;
end;
$$;

create or replace function public.touch_current_sync_device()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.paired_devices
  set last_sync_at = now()
  where auth_user_id = auth.uid() and removed_at is null;
  return new;
end;
$$;

revoke all on function public.touch_current_sync_device() from public;

do $$
declare table_name text;
begin
  foreach table_name in array array['markers', 'measurements', 'favorites', 'settings']
  loop
    execute format('create index if not exists %I on public.%I (group_uuid, updated_at, uuid)', table_name || '_group_updated_idx', table_name);
    execute format('drop trigger if exists %I on public.%I', table_name || '_assign_group', table_name);
    execute format('create trigger %I before insert on public.%I for each row execute function public.assign_sync_group()', table_name || '_assign_group', table_name);
    execute format('drop trigger if exists %I on public.%I', table_name || '_touch_device', table_name);
    execute format('create trigger %I after insert or update on public.%I for each statement execute function public.touch_current_sync_device()', table_name || '_touch_device', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_select_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_insert_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_update_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_select_group', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_insert_group', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_update_group', table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using (group_uuid = public.current_sync_group())',
      table_name || '_select_group', table_name
    );
    execute format(
      'create policy %I on public.%I for insert to authenticated with check (group_uuid = public.current_sync_group())',
      table_name || '_insert_group', table_name
    );
    execute format(
      'create policy %I on public.%I for update to authenticated using (group_uuid = public.current_sync_group()) with check (group_uuid = public.current_sync_group())',
      table_name || '_update_group', table_name
    );
  end loop;
end;
$$;
