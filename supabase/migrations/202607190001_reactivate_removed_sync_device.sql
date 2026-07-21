-- Reactivate a locally persistent device UUID after its previous pairing was
-- removed. The device receives a new isolated group and never regains access
-- to the group from which it was removed.

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
  v_removed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if nullif(trim(p_device_name), '') is null or
      nullif(trim(p_platform), '') is null then
    raise exception 'invalid device details';
  end if;

  select group_uuid, auth_user_id, removed_at
    into v_group_uuid, v_existing_auth, v_removed_at
  from public.paired_devices
  where device_uuid = p_device_uuid;

  if not found then
    insert into public.sync_groups (owner_device_uuid)
    values (p_device_uuid)
    returning group_uuid into v_group_uuid;

    insert into public.paired_devices (
      device_uuid, group_uuid, auth_user_id, device_name, platform
    ) values (
      p_device_uuid, v_group_uuid, auth.uid(), trim(p_device_name),
      trim(p_platform)
    );
  elsif v_removed_at is not null then
    if exists (
      select 1
      from public.paired_devices
      where auth_user_id = auth.uid()
        and device_uuid <> p_device_uuid
    ) then
      raise exception 'authentication already registered to another device';
    end if;

    delete from public.pairing_tokens
    where creator_device_uuid = p_device_uuid;

    insert into public.sync_groups (owner_device_uuid)
    values (p_device_uuid)
    returning group_uuid into v_group_uuid;

    update public.paired_devices
    set group_uuid = v_group_uuid,
        auth_user_id = auth.uid(),
        device_name = case
          when name_is_custom then device_name else trim(p_device_name)
        end,
        platform = trim(p_platform),
        paired_at = now(),
        last_sync_at = null,
        removed_at = null
    where device_uuid = p_device_uuid;
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

revoke all on function public.register_sync_device(uuid, text, text)
  from public;
grant execute on function public.register_sync_device(uuid, text, text)
  to authenticated;
