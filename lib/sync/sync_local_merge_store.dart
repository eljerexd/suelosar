import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../models/personal_marker.dart';
import '../models/saved_measurement.dart';
import 'sync_backend_adapter.dart';
import 'sync_operation.dart';
import 'sync_payload_policy.dart';
import 'sync_state.dart';

class SyncLocalMergeStore {
  const SyncLocalMergeStore();

  static const Map<SyncEntityType, String> _storageKeys = {
    SyncEntityType.marker: PersonalMarker.storageKey,
    SyncEntityType.measurement: SavedMeasurement.storageKey,
    SyncEntityType.favorite: FavoriteSoilFeature.storageKey,
  };

  Future<void> markUploaded(Iterable<PreparedSyncUpload> uploaded) async {
    final latest = <String, PreparedSyncUpload>{};
    for (final item in uploaded) {
      latest['${item.operation.entityType.name}:${item.operation.uuid}'] = item;
    }
    final preferences = await SharedPreferences.getInstance();
    for (final type in _storageKeys.keys) {
      final items = latest.values.where(
        (item) => item.operation.entityType == type,
      );
      if (items.isEmpty) continue;
      await _markListUploaded(preferences, type, items);
    }
  }

  Future<void> mergeRemoteChanges(
    Iterable<Map<String, Object?>> changes,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    for (final type in _storageKeys.keys) {
      final matching = changes.where(
        (change) => change['entityType'] == type.name,
      );
      if (matching.isEmpty) continue;
      await _mergeList(preferences, type, matching);
    }
  }

  Future<void> _markListUploaded(
    SharedPreferences preferences,
    SyncEntityType type,
    Iterable<PreparedSyncUpload> uploaded,
  ) async {
    final storageKey = _storageKeys[type]!;
    final records = _readList(preferences, storageKey);
    var changed = false;
    for (final item in uploaded) {
      final current = records[item.operation.uuid];
      if (current == null) continue;
      final uploadedDate = _date(item.payload['updatedAt']);
      final currentDate = _date(current['updatedAt']);
      if (uploadedDate == null || currentDate != uploadedDate) continue;
      current['syncState'] = SyncState.synced.name;
      changed = true;
    }
    if (changed) await _writeList(preferences, storageKey, records.values);
  }

  Future<void> _mergeList(
    SharedPreferences preferences,
    SyncEntityType type,
    Iterable<Map<String, Object?>> changes,
  ) async {
    final storageKey = _storageKeys[type]!;
    final records = _readList(preferences, storageKey);
    var changed = false;
    for (final change in changes) {
      final uuid = change['uuid']?.toString() ?? '';
      final remoteDate = _date(change['updatedAt']);
      if (uuid.isEmpty || remoteDate == null) continue;
      final local = records[uuid];
      final localDate = _date(local?['updatedAt']);
      if (localDate != null && !remoteDate.isAfter(localDate)) continue;
      if (change['deletedAt'] != null) {
        changed = records.remove(uuid) != null || changed;
        continue;
      }
      final payload = change['payload'];
      if (payload is! Map) continue;
      records[uuid] =
          SyncPayloadPolicy.mergeRemote(
              type,
              Map<String, Object?>.from(payload),
              local,
            )
            ..['uuid'] = uuid
            ..['createdAt'] = change['createdAt']
            ..['updatedAt'] = change['updatedAt']
            ..['deletedAt'] = change['deletedAt']
            ..['syncState'] = SyncState.synced.name;
      changed = true;
    }
    if (changed) await _writeList(preferences, storageKey, records.values);
  }

  Map<String, Map<String, Object?>> _readList(
    SharedPreferences preferences,
    String storageKey,
  ) {
    final records = <String, Map<String, Object?>>{};
    for (final encoded
        in preferences.getStringList(storageKey) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic>) continue;
        final uuid = decoded['uuid']?.toString() ?? '';
        if (uuid.isNotEmpty) records[uuid] = Map<String, Object?>.from(decoded);
      } catch (_) {
        // Existing local readers ignore malformed records as well.
      }
    }
    return records;
  }

  Future<void> _writeList(
    SharedPreferences preferences,
    String storageKey,
    Iterable<Map<String, Object?>> records,
  ) => preferences.setStringList(
    storageKey,
    records.map(jsonEncode).toList(growable: false),
  );

  DateTime? _date(Object? value) =>
      DateTime.tryParse(value?.toString() ?? '')?.toUtc();
}
