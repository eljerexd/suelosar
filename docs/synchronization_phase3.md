# SuelosAR synchronization: Phase 3

Phase 3 connects the offline queue to Supabase without changing the GIS or UI.
Local persistence remains authoritative while the device is offline.

## Configuration

Apply `supabase/migrations/202607150001_sync_schema.sql` to the Supabase
project and enable Anonymous Sign-Ins in Supabase Auth. Anonymous Auth users
receive the `authenticated` database role and an isolated `auth.uid()`; the
database does not grant the public `anon` role access to synchronization data.

Start or build the application with client-safe configuration:

```text
--dart-define=SUPABASE_URL=https://PROJECT.supabase.co
--dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

`SUPABASE_ANON_KEY` is accepted as a compatibility fallback. Never provide a
service-role or secret key to the Flutter application.

When the defines are absent, Supabase is not initialized and SuelosAR keeps its
existing local-only behavior.

## Database schema

The `markers`, `measurements`, `favorites`, and `settings` tables each store:

- `uuid`: stable entity identifier and primary key.
- `owner_id`: authenticated Supabase user used by RLS.
- `device_uuid`: device that produced the latest accepted version.
- `created_at`, `updated_at`, `deleted_at`: synchronization timestamps.
- `sync_state`: synchronization state persisted with the row.
- `payload`: entity-specific JSON data.

Deletes are tombstones (`deleted_at` is set). Client roles have no physical
delete grant. A database trigger keeps the newest `updated_at` version when an
older queued write arrives later.

## Synchronization flow

1. Existing repositories save locally and enqueue `SyncOperation` records.
2. `SyncCoordinator` asks the unchanged `SyncEngine` for an upload batch.
3. `SupabaseSyncBackendAdapter` groups final entity versions and upserts them.
4. Successful operations are marked locally as synced and acknowledged in the
   existing queue.
5. The adapter polls each entity table using a persistent per-table cursor.
6. `SyncLocalMergeStore` applies a remote record only when its `updated_at` is
   newer than the local version.
7. Failures leave operations in the queue and schedule bounded retries.

All work is asynchronous. The UI never calls Supabase and never waits for a
network request.

## Future Realtime integration

Realtime can later feed the same `SyncDownloadBatch`/`SyncLocalMergeStore`
boundary. It should subscribe only after authentication, request a catch-up
poll after reconnecting, and keep polling as the recovery path. Neither local
repositories nor GIS code need to change.

QR pairing can later link or transfer the authenticated owner while preserving
the persistent `device_uuid` already stored with every row.
