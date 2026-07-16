import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/repositories/sync_aware_local_repository.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';
import 'package:suelosar/sync/sync_payload_store.dart';
import 'package:suelosar/sync/sync_state.dart';
import 'package:suelosar/sync/sync_status.dart';

void main() {
  test(
    'persistent queue preserves order, retries, batches, and cancellation',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final queue = PersistentSyncQueue(storageKey: 'test.queue.lifecycle');
      final first = SyncOperation(
        uuid: 'entity-1',
        entityType: SyncEntityType.marker,
        operationType: SyncOperationType.create,
        createdAt: DateTime.utc(2026, 1, 1),
        retryCount: 0,
        payloadReference: 'marker:entity-1',
      );
      final second = SyncOperation(
        uuid: 'entity-2',
        entityType: SyncEntityType.measurement,
        operationType: SyncOperationType.update,
        createdAt: DateTime.utc(2026, 1, 2),
        retryCount: 0,
        payloadReference: 'measurement:entity-2',
      );

      await queue.enqueue(first);
      await queue.enqueue(second);
      final restored = PersistentSyncQueue(storageKey: 'test.queue.lifecycle');
      expect(
        (await restored.readAll()).map((operation) => operation.operationId),
        <String>[first.operationId, second.operationId],
      );
      expect(
        (await restored.takeBatch(1)).single.operationId,
        first.operationId,
      );

      await restored.incrementRetry(first.operationId);
      expect((await restored.readAll()).first.retryCount, 1);
      await restored.cancel(first.operationId);
      expect((await restored.readAll()).single.operationId, second.operationId);
    },
  );

  test(
    'repository automatically queues changes and retains delete tombstones',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final logs = <SyncLogEntry>[];
      final connectivity = ConnectivityService();
      final queue = PersistentSyncQueue(storageKey: 'test.queue.repository');
      final engine = SyncEngine(
        queue: queue,
        connectivity: connectivity,
        logger: SyncLogger(sink: logs.add),
      );
      final repository = SyncAwareLocalRepository(
        engine: engine,
        logger: SyncLogger(sink: logs.add),
      );
      await engine.start();

      final marker = PersonalMarker(
        id: 'marker-1',
        latitude: -36.5,
        longitude: -60,
        name: 'Muestreo',
        description: '',
        createdAt: DateTime.utc(2026, 2, 1),
        updatedAt: DateTime.utc(2026, 2, 1),
        syncState: SyncState.pendingUpload,
      );
      await repository.saveMarkers(<PersonalMarker>[marker]);
      await _waitForQueueLength(queue, 1);

      final edited = marker.copyWith(name: 'Muestreo editado');
      await repository.saveMarkers(<PersonalMarker>[edited]);
      await _waitForQueueLength(queue, 2);

      await repository.saveMarkers(const <PersonalMarker>[]);
      await _waitForQueueLength(queue, 3);
      final operations = await queue.readAll();
      expect(
        operations.map((operation) => operation.operationType),
        <SyncOperationType>[
          SyncOperationType.create,
          SyncOperationType.update,
          SyncOperationType.delete,
        ],
      );
      expect(engine.status.value, SyncStatus.waitingConnection);
      final prepared = await engine.prepareUploadBatch(maximum: 2);
      expect(prepared, hasLength(2));
      expect(
        prepared.map((item) => item.operation.operationType),
        <SyncOperationType>[SyncOperationType.create, SyncOperationType.update],
      );
      expect(prepared.first.payload['name'], 'Muestreo');
      expect(prepared.last.payload['name'], 'Muestreo editado');

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList(PersonalMarker.storageKey), isEmpty);
      final tombstones = await const SyncPayloadStore().readTombstones();
      expect(tombstones, hasLength(1));
      expect(tombstones.single['uuid'], marker.uuid);
      expect(tombstones.single['deletedAt'], isNotNull);

      connectivity.update(ConnectivityStatus.online);
      await Future<void>.delayed(Duration.zero);
      await _waitForStatus(engine, SyncStatus.queued);

      await engine.scheduleRetry(
        operations.first.operationId,
        delay: const Duration(milliseconds: 1),
      );
      expect((await queue.readAll()).first.retryCount, 1);
      expect(logs.any((entry) => entry.event == 'Retry scheduled'), isTrue);

      await engine.confirm(
        operations.map((operation) => operation.operationId),
      );
      expect(await queue.readAll(), isEmpty);
      expect(await const SyncPayloadStore().readTombstones(), isEmpty);
      expect(engine.status.value, SyncStatus.completed);
      await engine.dispose();
      await connectivity.dispose();
    },
  );

  test(
    'engine rebuilds missing queue operations from pending local data',
    () async {
      final measurement = SavedMeasurement(
        id: 'measurement-1',
        type: SavedMeasurementType.distance,
        name: 'Distancia 1',
        geometry: const [],
        createdAt: DateTime.utc(2026, 3, 1),
        updatedAt: DateTime.utc(2026, 3, 2),
        syncState: SyncState.pendingUpload,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        SavedMeasurement.storageKey: <String>[jsonEncode(measurement.toJson())],
      });
      final queue = PersistentSyncQueue(storageKey: 'test.queue.scan');
      final connectivity = ConnectivityService();
      final engine = SyncEngine(queue: queue, connectivity: connectivity);

      await engine.start();
      final operations = await queue.readAll();
      expect(operations, hasLength(1));
      expect(operations.single.uuid, measurement.uuid);
      expect(operations.single.entityType, SyncEntityType.measurement);
      expect(operations.single.operationType, SyncOperationType.update);
      expect(engine.status.value, SyncStatus.waitingConnection);

      await engine.scanPendingChanges();
      expect(await queue.readAll(), hasLength(1));
      await engine.dispose();
      await connectivity.dispose();
    },
  );
}

Future<void> _waitForQueueLength(
  PersistentSyncQueue queue,
  int expected,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if ((await queue.readAll()).length == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Queue did not reach $expected operations.');
}

Future<void> _waitForStatus(SyncEngine engine, SyncStatus expected) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (engine.status.value == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('SyncEngine did not reach ${expected.name}.');
}
