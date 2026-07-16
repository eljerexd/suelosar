import 'sync_operation.dart';

abstract final class SyncPayloadPolicy {
  static const Set<SyncEntityType> synchronizedEntityTypes = {
    SyncEntityType.marker,
    SyncEntityType.measurement,
    SyncEntityType.favorite,
  };

  static bool synchronizes(SyncEntityType type) =>
      synchronizedEntityTypes.contains(type);

  static Map<String, Object?> forUpload(
    SyncEntityType type,
    Map<String, Object?> payload,
  ) {
    final sanitized = Map<String, Object?>.from(payload);
    if (type == SyncEntityType.measurement) {
      sanitized.remove('isVisible');
    }
    return sanitized;
  }

  static Map<String, Object?> forChangeDetection(
    SyncEntityType type,
    Map<String, Object?> payload,
  ) {
    final comparable = forUpload(type, payload);
    comparable.remove('updatedAt');
    comparable.remove('syncState');
    return comparable;
  }

  static Map<String, Object?> mergeRemote(
    SyncEntityType type,
    Map<String, Object?> remote,
    Map<String, Object?>? local,
  ) {
    final merged = Map<String, Object?>.from(remote);
    if (type == SyncEntityType.measurement) {
      merged['isVisible'] = local?['isVisible'] as bool? ?? true;
    }
    return merged;
  }
}
