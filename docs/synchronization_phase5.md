# SuelosAR synchronization: Phase 5

Phase 5 adds secure device pairing without user-facing accounts, realtime, or
changes to `SyncEngine` and local repositories.

## Deployment

1. Keep Anonymous Sign-Ins enabled in Supabase Auth.
2. Apply `supabase/migrations/202607150001_sync_schema.sql` first.
3. Apply `supabase/migrations/202607160001_device_pairing.sql`.
4. Keep `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` in `--dart-define`.

The second migration enables `pgcrypto` for secure tokens and `pg_cron` for
expired-token cleanup.

## Database model

- `sync_groups`: group UUID, owner device UUID, creation timestamp.
- `paired_devices`: device UUID, group, anonymous Auth identity, display name,
  platform, pairing date, last synchronization, and removal timestamp.
- `pairing_tokens`: SHA-256 token hash, six-digit fallback code, group,
  creator, five-minute expiration, and one-use consumption metadata.
- `pairing_attempts`: short-lived server-side attempts used to rate-limit manual
  code claims.

The existing `markers`, `measurements`, `favorites`, and `settings` tables gain
a `group_uuid`. Their RLS policies use the authenticated device's current group.
The existing Flutter synchronization adapter does not need to know about the
group column; a database trigger assigns it.

## Pairing flow

1. Supabase Anonymous Auth creates an authenticated identity without email,
   password, or visible account creation.
2. The first device receives its own Sync Group.
3. `DevicePairingService` asks its backend adapter for a temporary session.
4. Supabase returns the opaque token once and stores only its SHA-256 hash.
5. The QR contains `suelosar://pair?token=<opaque-token>`. It contains no device
   UUID, group UUID, or Supabase configuration.
6. A second device scans the QR or submits the six-digit code.
7. `claim_pairing_session` locks and consumes the session atomically, moves the
   device into the target group, and returns the refreshed device list.
8. Subsequent polling uses the existing SyncEngine and repositories. RLS limits
   reads and writes to that shared group.

Tokens expire after five minutes, are never reusable, and are removed by the
scheduled cleanup. Manual attempts are rate-limited and return generic failures
to avoid leaking valid codes.

## Flutter boundaries

- UI -> `DevicePairingService`
- `DevicePairingService` -> `DevicePairingBackend`
- Production backend -> `SupabaseDevicePairingBackend`
- Tests -> in-memory backend fake

The synchronization screen never imports or calls Supabase. Realtime remains
disabled and can be added later without changing this pairing boundary.
