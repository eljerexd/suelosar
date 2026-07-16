import 'sync_state.dart';

abstract interface class SyncEntity {
  String get uuid;
  DateTime get createdAt;
  DateTime get updatedAt;
  DateTime? get deletedAt;
  SyncState get syncState;
}

DateTime? parseSyncDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}
