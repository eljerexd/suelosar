import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../models/personal_marker.dart';
import '../models/saved_measurement.dart';
import 'sync_backend_adapter.dart';
import 'sync_engine.dart';
import 'sync_local_merge_store.dart';
import 'sync_logger.dart';
import 'sync_operation.dart';
import 'sync_payload_policy.dart';
import 'sync_state.dart';
import 'uuid_v4.dart';

enum InitialHistorySyncStatus { idle, scanning, uploading, completed, error }

@immutable
class InitialHistoryEntityProgress {
  const InitialHistoryEntityProgress({this.completed = 0, this.total = 0});

  final int completed;
  final int total;
}

@immutable
class InitialHistorySyncProgress {
  const InitialHistorySyncProgress({
    this.status = InitialHistorySyncStatus.idle,
    this.groupUuid,
    this.markers = const InitialHistoryEntityProgress(),
    this.measurements = const InitialHistoryEntityProgress(),
    this.favorites = const InitialHistoryEntityProgress(),
    this.error,
  });

  final InitialHistorySyncStatus status;
  final String? groupUuid;
  final InitialHistoryEntityProgress markers;
  final InitialHistoryEntityProgress measurements;
  final InitialHistoryEntityProgress favorites;
  final String? error;

  bool get isRunning =>
      status == InitialHistorySyncStatus.scanning ||
      status == InitialHistorySyncStatus.uploading;

  int get total => markers.total + measurements.total + favorites.total;

  InitialHistoryEntityProgress forType(SyncEntityType type) => switch (type) {
    SyncEntityType.marker => markers,
    SyncEntityType.measurement => measurements,
    SyncEntityType.favorite => favorites,
    SyncEntityType.settings => const InitialHistoryEntityProgress(),
  };
}

class InitialHistorySync {
  InitialHistorySync({
    required this.engine,
    required this.backend,
    this.localStore = const SyncLocalMergeStore(),
    SyncLogger? logger,
  }) : _logger = logger ?? SyncLogger.instance;

  static const String groupStorageKey = 'sync.group_uuid';
  static const String completedGroupsStorageKey =
      'sync.initial_history.completed_groups';
  static const String incrementalCursorStorageKey = 'sync.download_cursor';

  final SyncEngine engine;
  final SyncBackendAdapter backend;
  final SyncLocalMergeStore localStore;
  final SyncLogger _logger;
  final ValueNotifier<InitialHistorySyncProgress> progress = ValueNotifier(
    const InitialHistorySyncProgress(),
  );

  String? _preparedGroupUuid;
  bool _preparing = false;
  final Set<String> _pendingEntityKeys = <String>{};
  final Map<SyncEntityType, int> _completedByType = <SyncEntityType, int>{};
  final Map<SyncEntityType, int> _totalByType = <SyncEntityType, int>{};

  Future<void> prepareIfNeeded() async {
    if (_preparing) return;
    final preferences = await SharedPreferences.getInstance();
    final groupUuid = preferences.getString(groupStorageKey)?.trim() ?? '';
    if (!UuidV4.isValid(groupUuid) || _preparedGroupUuid == groupUuid) return;

    final completedGroups = _completedGroups(preferences);
    if (completedGroups.contains(groupUuid)) return;

    _preparing = true;
    _preparedGroupUuid = groupUuid;
    await preferences.remove(incrementalCursorStorageKey);
    _pendingEntityKeys.clear();
    _completedByType.clear();
    _totalByType.clear();
    progress.value = InitialHistorySyncProgress(
      status: InitialHistorySyncStatus.scanning,
      groupUuid: groupUuid,
    );

    try {
      final localRecords = _readLocalRecords(preferences);
      final eligible = localRecords
          .where(
            (record) =>
                record.deletedAt == null &&
                (record.syncState == SyncState.local ||
                    record.syncState == SyncState.pendingUpload),
          )
          .toList(growable: false);
      for (final type in SyncPayloadPolicy.synchronizedEntityTypes) {
        _totalByType[type] = eligible
            .where((record) => record.entityType == type)
            .length;
        _completedByType[type] = 0;
      }
      _publishProgress(InitialHistorySyncStatus.scanning);

      final remoteChanges = await _downloadAllRemoteChanges();
      final remoteByEntity = <String, Map<String, Object?>>{};
      for (final change in remoteChanges) {
        final key = _changeKey(change);
        final updatedAt = _date(change['updatedAt']);
        if (key == null || updatedAt == null) continue;
        final current = remoteByEntity[key];
        final currentDate = _date(current?['updatedAt']);
        if (currentDate == null || updatedAt.isAfter(currentDate)) {
          remoteByEntity[key] = change;
        }
      }

      await localStore.mergeRemoteChanges(remoteChanges);
      final queued = await engine.queue.readAll();
      final queuedByEntity = <String, List<SyncOperation>>{};
      for (final operation in queued) {
        queuedByEntity
            .putIfAbsent(
              _entityKey(operation.entityType, operation.uuid),
              () => <SyncOperation>[],
            )
            .add(operation);
      }

      final uploads = <SyncLocalChange>[];
      for (final record in eligible) {
        final key = _entityKey(record.entityType, record.uuid);
        final remote = remoteByEntity[key];
        final remoteUpdatedAt = _date(remote?['updatedAt']);
        final requiresUpload =
            remoteUpdatedAt == null ||
            record.updatedAt.isAfter(remoteUpdatedAt);
        if (!requiresUpload) {
          for (final operation in queuedByEntity.remove(key) ?? const []) {
            await engine.cancel(operation.operationId);
          }
          _completedByType.update(record.entityType, (value) => value + 1);
          continue;
        }

        _pendingEntityKeys.add(key);
        final existing = queuedByEntity[key] ?? const <SyncOperation>[];
        if (existing.any(
          (operation) => operation.operationType != SyncOperationType.delete,
        )) {
          continue;
        }
        for (final operation in existing) {
          await engine.cancel(operation.operationId);
        }
        uploads.add(
          SyncLocalChange(
            entityType: record.entityType,
            operationType: SyncOperationType.create,
            uuid: record.uuid,
            payload: record.payload,
          ),
        );
      }
      await engine.recordLocalChanges(uploads);

      _publishProgress(
        _pendingEntityKeys.isEmpty
            ? InitialHistorySyncStatus.scanning
            : InitialHistorySyncStatus.uploading,
      );
      _logger.log('Initial history synchronization prepared', {
        'groupUuid': groupUuid,
        'entities': eligible.length,
        'pendingUploads': _pendingEntityKeys.length,
      });
    } catch (error) {
      progress.value = InitialHistorySyncProgress(
        status: InitialHistorySyncStatus.error,
        groupUuid: groupUuid,
        markers: _entityProgress(SyncEntityType.marker),
        measurements: _entityProgress(SyncEntityType.measurement),
        favorites: _entityProgress(SyncEntityType.favorite),
        error: error.toString(),
      );
      _preparedGroupUuid = null;
      rethrow;
    } finally {
      _preparing = false;
    }
  }

  void recordUploaded(Iterable<PreparedSyncUpload> uploaded) {
    for (final item in uploaded) {
      final type = item.operation.entityType;
      final key = _entityKey(type, item.operation.uuid);
      if (_pendingEntityKeys.remove(key)) {
        _completedByType.update(type, (value) => value + 1);
      }
    }
    if (_preparedGroupUuid != null) {
      _publishProgress(InitialHistorySyncStatus.uploading);
    }
  }

  Future<void> completeIfQueueEmpty() async {
    final groupUuid = _preparedGroupUuid;
    if (groupUuid == null || (await engine.queue.readAll()).isNotEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final completedGroups = _completedGroups(preferences)..add(groupUuid);
    await preferences.setStringList(
      completedGroupsStorageKey,
      completedGroups.toList(growable: false)..sort(),
    );
    _pendingEntityKeys.clear();
    _publishProgress(InitialHistorySyncStatus.completed);
    _logger.log('Initial history synchronization completed', {
      'groupUuid': groupUuid,
      'entities': progress.value.total,
    });
  }

  Future<void> resetCurrentGroup() async {
    final preferences = await SharedPreferences.getInstance();
    final groupUuid = preferences.getString(groupStorageKey)?.trim() ?? '';
    if (!UuidV4.isValid(groupUuid)) return;
    final completedGroups = _completedGroups(preferences)..remove(groupUuid);
    await preferences.setStringList(
      completedGroupsStorageKey,
      completedGroups.toList(growable: false)..sort(),
    );
    _preparedGroupUuid = null;
    _pendingEntityKeys.clear();
    progress.value = InitialHistorySyncProgress(groupUuid: groupUuid);
  }

  Future<List<Map<String, Object?>>> _downloadAllRemoteChanges() async {
    final changes = <Map<String, Object?>>[];
    String? cursor;
    for (var page = 0; page < 10000; page++) {
      final batch = await backend.download(SyncDownloadRequest(cursor: cursor));
      changes.addAll(batch.changes);
      final nextCursor = batch.nextCursor;
      if (batch.changes.isEmpty || nextCursor == null || nextCursor == cursor) {
        break;
      }
      cursor = nextCursor;
    }
    return changes;
  }

  List<_LocalSyncRecord> _readLocalRecords(SharedPreferences preferences) {
    final records = <_LocalSyncRecord>[];
    void addList(String storageKey, SyncEntityType type) {
      for (final encoded
          in preferences.getStringList(storageKey) ?? const <String>[]) {
        try {
          final decoded = jsonDecode(encoded);
          if (decoded is Map<String, dynamic>) {
            final record = _LocalSyncRecord.fromJson(type, decoded);
            if (record != null) records.add(record);
          }
        } catch (_) {
          _logger.log('Initial history record skipped', {
            'entityType': type.name,
            'reason': 'malformed',
          });
        }
      }
    }

    addList(PersonalMarker.storageKey, SyncEntityType.marker);
    addList(SavedMeasurement.storageKey, SyncEntityType.measurement);
    addList(FavoriteSoilFeature.storageKey, SyncEntityType.favorite);
    return records;
  }

  Set<String> _completedGroups(SharedPreferences preferences) =>
      preferences
          .getStringList(completedGroupsStorageKey)
          ?.where(UuidV4.isValid)
          .toSet() ??
      <String>{};

  void _publishProgress(InitialHistorySyncStatus status) {
    progress.value = InitialHistorySyncProgress(
      status: status,
      groupUuid: _preparedGroupUuid,
      markers: _entityProgress(SyncEntityType.marker),
      measurements: _entityProgress(SyncEntityType.measurement),
      favorites: _entityProgress(SyncEntityType.favorite),
    );
  }

  InitialHistoryEntityProgress _entityProgress(SyncEntityType type) =>
      InitialHistoryEntityProgress(
        completed: _completedByType[type] ?? 0,
        total: _totalByType[type] ?? 0,
      );

  String _entityKey(SyncEntityType type, String uuid) => '${type.name}:$uuid';

  String? _changeKey(Map<String, Object?> change) {
    final typeName = change['entityType']?.toString();
    final uuid = change['uuid']?.toString() ?? '';
    final type = SyncEntityType.values
        .where((candidate) => candidate.name == typeName)
        .firstOrNull;
    return type == null || !UuidV4.isValid(uuid)
        ? null
        : _entityKey(type, uuid);
  }

  DateTime? _date(Object? value) =>
      DateTime.tryParse(value?.toString() ?? '')?.toUtc();
}

class _LocalSyncRecord {
  const _LocalSyncRecord({
    required this.entityType,
    required this.uuid,
    required this.updatedAt,
    required this.deletedAt,
    required this.syncState,
    required this.payload,
  });

  final SyncEntityType entityType;
  final String uuid;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SyncState syncState;
  final Map<String, Object?> payload;

  static _LocalSyncRecord? fromJson(
    SyncEntityType type,
    Map<String, dynamic> json,
  ) {
    final uuid = json['uuid']?.toString() ?? '';
    final updatedAt = DateTime.tryParse(
      json['updatedAt']?.toString() ?? '',
    )?.toUtc();
    if (!UuidV4.isValid(uuid) || updatedAt == null) return null;
    return _LocalSyncRecord(
      entityType: type,
      uuid: uuid,
      updatedAt: updatedAt,
      deletedAt: DateTime.tryParse(
        json['deletedAt']?.toString() ?? '',
      )?.toUtc(),
      syncState: SyncState.fromJson(json['syncState']),
      payload: SyncPayloadPolicy.forUpload(
        type,
        Map<String, Object?>.from(json),
      ),
    );
  }
}
