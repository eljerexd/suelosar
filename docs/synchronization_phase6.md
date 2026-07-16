# Phase 6: Initial history synchronization

## Flow

`InitialHistorySync` runs through `SyncCoordinator` after a valid Sync Group is
available. Completion is stored per group in SharedPreferences under
`sync.initial_history.completed_groups`.

1. Read markers, measurements, favorites, and the synchronization-ready
   settings record from their existing local stores.
2. Keep non-deleted records whose state is `local` or `pendingUpload`.
3. Download the remote group snapshot through `SyncBackendAdapter` and merge
   newer cloud records through `SyncLocalMergeStore`.
4. Compare records by UUID and `updatedAt`.
5. Enqueue missing or newer local records through `SyncEngine`; existing queue
   operations are reused.
6. Let `SyncCoordinator` upload the queue in its existing 50-operation batches.
7. Mark the group complete only after the persistent queue is empty.

No UUID, local ID, timestamp, geometry, metadata, or attribute is regenerated.
Supabase's `keep_newest_sync_version` trigger rejects an older incoming version,
while the local merge store accepts only a strictly newer remote version.

## Idempotency and recovery

A completed group is skipped on later launches. A restored database without the
group completion marker runs bootstrap again safely. The advanced
`Volver a subir datos locales` action clears only that marker and compares local
history with the cloud again; it does not delete local records.

## UI

The synchronization page exposes bootstrap progress for each entity type and a
completion message. The advanced re-upload action uses the existing
confirmation-dialog and synchronization-service path. Pairing or registering a
device triggers synchronization immediately instead of waiting for the next
poll interval.

## Extension points

- New synchronizable entity types can be added to `_readLocalRecords` and the
  progress model without bypassing the queue.
- Backend batching, retry, and conflict behavior remain owned by
  `SyncEngine`, `SyncCoordinator`, and `SyncBackendAdapter`.
- Realtime can wake the coordinator later without changing bootstrap storage or
  repository behavior.
