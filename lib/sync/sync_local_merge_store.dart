import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings_sync_record.dart';
import '../models/favorite_soil_feature.dart';
import '../models/personal_marker.dart';
import '../models/saved_measurement.dart';
import '../services/settings_service.dart';
import 'sync_backend_adapter.dart';
import 'sync_operation.dart';
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
    final settings = latest.values.where(
      (item) => item.operation.entityType == SyncEntityType.settings,
    );
    if (settings.isNotEmpty) {
      await _markSettingsUploaded(preferences, settings.last);
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
    for (final change in changes.where(
      (change) => change['entityType'] == SyncEntityType.settings.name,
    )) {
      await _mergeSettings(preferences, change);
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

  Future<void> _markSettingsUploaded(
    SharedPreferences preferences,
    PreparedSyncUpload item,
  ) async {
    final current = _readSettings(preferences);
    if (current == null || current.uuid != item.operation.uuid) return;
    final uploadedDate = _date(item.payload['updatedAt']);
    if (uploadedDate == null || current.updatedAt != uploadedDate) return;
    final synced = AppSettingsSyncRecord(
      values: current.values,
      uuid: current.uuid,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      deletedAt: current.deletedAt,
      syncState: SyncState.synced,
    );
    await SettingsService.instance.applyRemoteSyncRecord(synced);
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
      records[uuid] = Map<String, Object?>.from(payload)
        ..['uuid'] = uuid
        ..['createdAt'] = change['createdAt']
        ..['updatedAt'] = change['updatedAt']
        ..['deletedAt'] = change['deletedAt']
        ..['syncState'] = SyncState.synced.name;
      changed = true;
    }
    if (changed) await _writeList(preferences, storageKey, records.values);
  }

  Future<void> _mergeSettings(
    SharedPreferences preferences,
    Map<String, Object?> change,
  ) async {
    if (change['deletedAt'] != null) return;
    final payload = change['payload'];
    if (payload is! Map) return;
    final current = _readSettings(preferences);
    final remoteDate = _date(change['updatedAt']);
    if (remoteDate == null ||
        (current != null && !remoteDate.isAfter(current.updatedAt))) {
      return;
    }
    final remote = AppSettingsSyncRecord.fromJson(
      Map<String, dynamic>.from(payload)
        ..['uuid'] = change['uuid']
        ..['createdAt'] = change['createdAt']
        ..['updatedAt'] = change['updatedAt']
        ..['deletedAt'] = change['deletedAt']
        ..['syncState'] = SyncState.synced.name,
    );
    await SettingsService.instance.applyRemoteSyncRecord(remote);
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

  AppSettingsSyncRecord? _readSettings(SharedPreferences preferences) {
    final encoded = preferences.getString(AppSettingsSyncRecord.storageKey);
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map<String, dynamic>
          ? AppSettingsSyncRecord.fromJson(decoded)
          : null;
    } catch (_) {
      return null;
    }
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
