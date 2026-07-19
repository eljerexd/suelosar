import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../models/personal_marker.dart';
import '../models/saved_measurement.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_logger.dart';
import '../sync/sync_operation.dart';
import '../sync/sync_payload_policy.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';

class SyncAwareLocalRepository {
  SyncAwareLocalRepository({SyncEngine? engine, SyncLogger? logger})
    : _engine = engine ?? SyncEngine.instance,
      _logger = logger ?? SyncLogger.instance;

  static final SyncAwareLocalRepository instance = SyncAwareLocalRepository();

  final SyncEngine _engine;
  final SyncLogger _logger;

  Future<void> saveMarkers(Iterable<PersonalMarker> markers) => _saveList(
    storageKey: PersonalMarker.storageKey,
    entityType: SyncEntityType.marker,
    records: markers.map((marker) => marker.toJson()),
  );

  Future<void> saveMeasurements(Iterable<SavedMeasurement> measurements) =>
      _saveList(
        storageKey: SavedMeasurement.storageKey,
        entityType: SyncEntityType.measurement,
        records: measurements.map((measurement) => measurement.toJson()),
      );

  Future<void> saveFavorites(Iterable<FavoriteSoilFeature> favorites) =>
      _saveList(
        storageKey: FavoriteSoilFeature.storageKey,
        entityType: SyncEntityType.favorite,
        records: favorites.map((favorite) => favorite.toJson()),
      );

  Future<void> _saveList({
    required String storageKey,
    required SyncEntityType entityType,
    required Iterable<Map<String, Object?>> records,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final previous = _decodeByUuid(preferences.getStringList(storageKey));
    final nextRecords = records.toList(growable: false);
    final next = <String, Map<String, Object?>>{
      for (final record in nextRecords) record['uuid']!.toString(): record,
    };
    await preferences.setStringList(
      storageKey,
      nextRecords.map(jsonEncode).toList(growable: false),
    );
    final changes = <SyncLocalChange>[];
    for (final entry in next.entries) {
      final previousRecord = previous[entry.key];
      final syncPayload = SyncPayloadPolicy.forUpload(entityType, entry.value);
      if (previousRecord != null &&
          jsonEncode(
                SyncPayloadPolicy.forChangeDetection(
                  entityType,
                  previousRecord,
                ),
              ) ==
              jsonEncode(
                SyncPayloadPolicy.forChangeDetection(entityType, entry.value),
              )) {
        continue;
      }
      changes.add(
        SyncLocalChange(
          entityType: entityType,
          operationType: previousRecord == null
              ? SyncOperationType.create
              : SyncOperationType.update,
          uuid: entry.key,
          payload: syncPayload,
        ),
      );
    }

    for (final entry in previous.entries) {
      if (next.containsKey(entry.key)) continue;
      final deletedAt = DateTime.now().toUtc();
      final tombstone = Map<String, Object?>.from(entry.value)
        ..['uuid'] = entry.key
        ..['updatedAt'] = deletedAt.toIso8601String()
        ..['deletedAt'] = deletedAt.toIso8601String()
        ..['syncState'] = SyncState.pendingUpload.name;
      changes.add(
        SyncLocalChange(
          entityType: entityType,
          operationType: SyncOperationType.delete,
          uuid: entry.key,
          payload: SyncPayloadPolicy.forUpload(entityType, tombstone),
        ),
      );
    }
    if (changes.isNotEmpty) unawaited(_recordInBackground(changes));
  }

  Future<void> _recordInBackground(List<SyncLocalChange> changes) async {
    try {
      await _engine.recordLocalChanges(changes);
    } catch (error) {
      _logger.log('Local change enqueue failed', {
        'entityTypes': changes.map((change) => change.entityType.name).toSet(),
        'count': changes.length,
        'error': error.toString(),
      });
    }
  }

  Map<String, Map<String, Object?>> _decodeByUuid(List<String>? encoded) {
    final records = <String, Map<String, Object?>>{};
    for (final value in encoded ?? const <String>[]) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is! Map<String, dynamic>) continue;
        var uuid = decoded['uuid']?.toString() ?? '';
        if (!UuidV4.isValid(uuid)) uuid = UuidV4.generate();
        records[uuid] = Map<String, Object?>.from(decoded)..['uuid'] = uuid;
      } catch (_) {
        // Existing screens already skip malformed records; preserve that rule.
      }
    }
    return records;
  }
}
