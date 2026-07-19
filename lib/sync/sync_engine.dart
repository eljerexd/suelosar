import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../models/personal_marker.dart';
import '../models/saved_measurement.dart';
import '../services/connectivity_service.dart';
import 'persistent_sync_queue.dart';
import 'sync_backend_adapter.dart';
import 'sync_logger.dart';
import 'sync_operation.dart';
import 'sync_payload_store.dart';
import 'sync_state.dart';
import 'sync_status.dart';
import 'uuid_v4.dart';

@immutable
class SyncLocalChange {
  const SyncLocalChange({
    required this.entityType,
    required this.operationType,
    required this.uuid,
    required this.payload,
  });

  final SyncEntityType entityType;
  final SyncOperationType operationType;
  final String uuid;
  final Map<String, Object?> payload;
}

class SyncEngine {
  SyncEngine({
    PersistentSyncQueue? queue,
    SyncPayloadStore? payloadStore,
    ConnectivityService? connectivity,
    SyncLogger? logger,
  }) : queue = queue ?? PersistentSyncQueue(),
       payloadStore = payloadStore ?? const SyncPayloadStore(),
       connectivity = connectivity ?? ConnectivityService.instance,
       logger = logger ?? SyncLogger.instance;

  static final SyncEngine instance = SyncEngine();

  final PersistentSyncQueue queue;
  final SyncPayloadStore payloadStore;
  final ConnectivityService connectivity;
  final SyncLogger logger;
  final ValueNotifier<SyncStatus> status = ValueNotifier(SyncStatus.idle);
  final StreamController<void> _localChanges =
      StreamController<void>.broadcast();
  final Map<String, Timer> _retryTimers = <String, Timer>{};
  StreamSubscription<ConnectivityStatus>? _connectivitySubscription;
  bool _started = false;
  Future<void> _operationChain = Future<void>.value();

  Stream<void> get localChanges => _localChanges.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    logger.log('SyncEngine started');
    _connectivitySubscription = connectivity.changes.listen(
      _handleConnectivityChanged,
    );
    await _discardLegacySettingsOperations();
    await scanPendingChanges();
  }

  Future<void> scanPendingChanges() => _serialize(() async {
    status.value = SyncStatus.scanning;
    logger.log('Queue scanned');
    final preferences = await SharedPreferences.getInstance();
    final existing = await queue.readAll();
    final queuedEntities = {
      for (final operation in existing)
        '${operation.entityType.name}:${operation.uuid}',
    };
    var added = 0;
    added += await _scanList(
      preferences,
      PersonalMarker.storageKey,
      SyncEntityType.marker,
      queuedEntities,
    );
    added += await _scanList(
      preferences,
      SavedMeasurement.storageKey,
      SyncEntityType.measurement,
      queuedEntities,
    );
    added += await _scanList(
      preferences,
      FavoriteSoilFeature.storageKey,
      SyncEntityType.favorite,
      queuedEntities,
    );
    final total = (await queue.readAll()).length;
    logger.log('$added operations queued', {'total': total});
    _updateWaitingStatus(total);
  });

  Future<void> recordLocalChange({
    required SyncEntityType entityType,
    required SyncOperationType operationType,
    required String uuid,
    required Map<String, Object?> payload,
  }) => recordLocalChanges(<SyncLocalChange>[
    SyncLocalChange(
      entityType: entityType,
      operationType: operationType,
      uuid: uuid,
      payload: payload,
    ),
  ]);

  Future<void> recordLocalChanges(Iterable<SyncLocalChange> changes) {
    final batch = changes.toList(growable: false);
    if (batch.isEmpty) return Future<void>.value();
    return _serialize(() => _recordLocalChangesNow(batch));
  }

  Future<void> cancel(String operationId) => _serialize(() async {
    final operations = await queue.readAll();
    final operation = operations
        .where((candidate) => candidate.operationId == operationId)
        .firstOrNull;
    if (operation == null) return;
    await queue.cancel(operationId);
    _retryTimers.remove(operationId)?.cancel();
    final remaining = await queue.readAll();
    if (!remaining.any(
      (candidate) => candidate.payloadReference == operation.payloadReference,
    )) {
      await payloadStore.remove(operation.payloadReference);
    }
    _updateWaitingStatus(remaining.length);
  });

  Future<void> scheduleRetry(
    String operationId, {
    Duration delay = const Duration(seconds: 5),
  }) => _serialize(() async {
    await queue.incrementRetry(operationId);
    _retryTimers.remove(operationId)?.cancel();
    _retryTimers[operationId] = Timer(delay, () {
      _retryTimers.remove(operationId);
      unawaited(_refreshQueueStatus());
    });
    logger.log('Retry scheduled', {
      'operationId': operationId,
      'delayMs': delay.inMilliseconds,
    });
  });

  Future<List<PreparedSyncUpload>> prepareUploadBatch({int maximum = 50}) =>
      _serialize(() async {
        status.value = SyncStatus.preparing;
        final operations = await queue.takeBatch(maximum);
        final prepared = <PreparedSyncUpload>[];
        for (final operation in operations) {
          final payload = await payloadStore.get(operation.payloadReference);
          if (payload == null) {
            logger.log('Payload missing', {
              'operationId': operation.operationId,
              'payloadReference': operation.payloadReference,
            });
            continue;
          }
          prepared.add(
            PreparedSyncUpload(operation: operation, payload: payload),
          );
        }
        _updateWaitingStatus(operations.length);
        return List<PreparedSyncUpload>.unmodifiable(prepared);
      });

  Future<void> confirm(Iterable<String> operationIds) => _serialize(() async {
    final ids = operationIds.toSet();
    final operations = await queue.readAll();
    final confirmed = operations
        .where((operation) => ids.contains(operation.operationId))
        .toList(growable: false);
    await queue.removeAll(ids);
    final remaining = await queue.readAll();
    final retainedReferences = remaining
        .map((operation) => operation.payloadReference)
        .toSet();
    await payloadStore.removeAll(
      confirmed
          .map((operation) => operation.payloadReference)
          .where((reference) => !retainedReferences.contains(reference)),
    );
    status.value = remaining.isEmpty ? SyncStatus.completed : SyncStatus.queued;
    if (remaining.isEmpty) logger.log('Queue completed');
  });

  Future<void> dispose() async {
    _started = false;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    await _localChanges.close();
    status.dispose();
  }

  Future<void> _discardLegacySettingsOperations() async {
    final operations = await queue.readAll();
    for (final operation in operations.where(
      (candidate) => candidate.entityType == SyncEntityType.settings,
    )) {
      await cancel(operation.operationId);
    }
  }

  Future<void> _recordLocalChangesNow(List<SyncLocalChange> changes) async {
    if (changes.isEmpty) return;
    status.value = SyncStatus.preparing;
    final createdAt = DateTime.now().toUtc();
    final operations = <SyncOperation>[];
    final payloads = <String, Map<String, Object?>>{};
    final tombstoneReferences = <String>{};
    for (final change in changes) {
      final operationId = UuidV4.generate();
      final payloadReference =
          '${change.entityType.name}:${change.uuid}:$operationId';
      operations.add(
        SyncOperation(
          operationId: operationId,
          uuid: change.uuid,
          entityType: change.entityType,
          operationType: change.operationType,
          createdAt: createdAt,
          retryCount: 0,
          payloadReference: payloadReference,
        ),
      );
      payloads[payloadReference] = change.payload;
      if (change.operationType == SyncOperationType.delete) {
        tombstoneReferences.add(payloadReference);
      }
    }
    await payloadStore.putAll(
      payloads,
      tombstoneReferences: tombstoneReferences,
    );
    await queue.enqueueAll(operations);
    final total = (await queue.readAll()).length;
    logger.log('${operations.length} operations queued', {'total': total});
    _updateWaitingStatus(total);
    _localChanges.add(null);
  }

  Future<int> _scanList(
    SharedPreferences preferences,
    String storageKey,
    SyncEntityType entityType,
    Set<String> queuedEntities,
  ) async {
    var added = 0;
    final changes = <SyncLocalChange>[];
    for (final encoded
        in preferences.getStringList(storageKey) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic> ||
            decoded['syncState'] != SyncState.pendingUpload.name) {
          continue;
        }
        final uuid = decoded['uuid']?.toString() ?? '';
        final key = '${entityType.name}:$uuid';
        if (uuid.isEmpty || queuedEntities.contains(key)) continue;
        final deletedAt = decoded['deletedAt'];
        final createdAt = DateTime.tryParse(
          decoded['createdAt']?.toString() ?? '',
        );
        final updatedAt = DateTime.tryParse(
          decoded['updatedAt']?.toString() ?? '',
        );
        final operationType = deletedAt != null
            ? SyncOperationType.delete
            : createdAt != null && updatedAt != null && updatedAt == createdAt
            ? SyncOperationType.create
            : SyncOperationType.update;
        changes.add(
          SyncLocalChange(
            entityType: entityType,
            operationType: operationType,
            uuid: uuid,
            payload: Map<String, Object?>.from(decoded),
          ),
        );
        queuedEntities.add(key);
        added++;
      } catch (_) {
        logger.log('Entity scan skipped', {
          'entityType': entityType.name,
          'reason': 'malformed',
        });
      }
    }
    await _recordLocalChangesNow(changes);
    return added;
  }

  void _handleConnectivityChanged(ConnectivityStatus connectivityStatus) {
    logger.log(
      connectivityStatus == ConnectivityStatus.online
          ? 'Connectivity online'
          : 'Waiting for connectivity',
    );
    unawaited(_refreshQueueStatus());
  }

  Future<void> _refreshQueueStatus() async {
    final total = (await queue.readAll()).length;
    if (total == 0 &&
        (status.value == SyncStatus.completed ||
            status.value == SyncStatus.error)) {
      return;
    }
    _updateWaitingStatus(total);
  }

  void _updateWaitingStatus(int queuedCount) {
    if (queuedCount == 0) {
      status.value = SyncStatus.idle;
      return;
    }
    status.value = connectivity.isOnline
        ? SyncStatus.queued
        : SyncStatus.waitingConnection;
    if (!connectivity.isOnline) {
      logger.log('Waiting for connectivity', {'queued': queuedCount});
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationChain = _operationChain.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        status.value = SyncStatus.error;
        logger.log('Sync error', {'error': error.toString()});
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
