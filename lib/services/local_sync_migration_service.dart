import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../models/personal_marker.dart';
import '../models/saved_measurement.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';

class LocalSyncMigrationService {
  const LocalSyncMigrationService();

  Future<void> migrate() async {
    final preferences = await SharedPreferences.getInstance();
    await _migrateList(
      preferences,
      PersonalMarker.storageKey,
      (json) => PersonalMarker.fromJson(json).toJson(),
    );
    await _migrateList(
      preferences,
      SavedMeasurement.storageKey,
      (json) => SavedMeasurement.fromJson(json).toJson(),
    );
    await _migrateList(
      preferences,
      FavoriteSoilFeature.storageKey,
      (json) => FavoriteSoilFeature.fromJson(json).toJson(),
    );
  }

  Future<void> _migrateList(
    SharedPreferences preferences,
    String storageKey,
    Map<String, Object?> Function(Map<String, dynamic>) migrate,
  ) async {
    final stored = preferences.getStringList(storageKey);
    if (stored == null || stored.isEmpty) return;
    var changed = false;
    final migrated = <String>[];
    for (final encoded in stored) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic> || _hasSyncMetadata(decoded)) {
          migrated.add(encoded);
          continue;
        }
        migrated.add(jsonEncode(migrate(decoded)));
        changed = true;
      } catch (_) {
        // Preserve malformed records byte-for-byte; existing readers already
        // skip them and migration must never cause local data loss.
        migrated.add(encoded);
      }
    }
    if (changed) {
      await preferences.setStringList(storageKey, migrated);
    }
  }

  bool _hasSyncMetadata(Map<String, dynamic> json) {
    final uuid = json['uuid']?.toString() ?? '';
    final syncState = json['syncState']?.toString();
    return UuidV4.isValid(uuid) &&
        DateTime.tryParse(json['createdAt']?.toString() ?? '') != null &&
        DateTime.tryParse(json['updatedAt']?.toString() ?? '') != null &&
        json.containsKey('deletedAt') &&
        SyncState.values.any((state) => state.name == syncState);
  }
}
