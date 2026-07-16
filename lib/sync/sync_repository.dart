import 'sync_entity.dart';

/// Contract for a future offline-first synchronization backend.
abstract interface class SyncRepository<T extends SyncEntity> {
  Future<List<T>> readPendingChanges();

  Future<void> saveRemoteChanges(Iterable<T> entities);

  Future<void> markAsSynced(Iterable<String> uuids);

  Future<void> markAsConflicted(Iterable<String> uuids);
}
