import '../sync/sync_entity.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';

class AppSettingsSyncRecord implements SyncEntity {
  AppSettingsSyncRecord({
    required this.values,
    String? uuid,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.local,
  }) : uuid = uuid ?? UuidV4.generate(),
       createdAt = (createdAt ?? DateTime.now()).toUtc(),
       updatedAt = (updatedAt ?? createdAt ?? DateTime.now()).toUtc();

  static const String storageKey = 'settings.sync_record';

  final Map<String, Object?> values;
  @override
  final String uuid;
  @override
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  @override
  final DateTime? deletedAt;
  @override
  final SyncState syncState;

  AppSettingsSyncRecord withValues(Map<String, Object?> nextValues) {
    return AppSettingsSyncRecord(
      values: Map<String, Object?>.unmodifiable(nextValues),
      uuid: uuid,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt,
      syncState: SyncState.pendingUpload,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'values': values,
    'uuid': uuid,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'syncState': syncState.name,
  };

  factory AppSettingsSyncRecord.fromJson(Map<String, dynamic> json) {
    final rawValues = json['values'];
    final createdAt =
        parseSyncDate(json['createdAt']) ?? DateTime.now().toUtc();
    final storedUuid = json['uuid']?.toString() ?? '';
    return AppSettingsSyncRecord(
      values: rawValues is Map
          ? Map<String, Object?>.from(rawValues)
          : const <String, Object?>{},
      uuid: UuidV4.isValid(storedUuid) ? storedUuid : UuidV4.generate(),
      createdAt: createdAt,
      updatedAt: parseSyncDate(json['updatedAt']) ?? createdAt,
      deletedAt: parseSyncDate(json['deletedAt']),
      syncState: SyncState.fromJson(json['syncState']),
    );
  }
}
