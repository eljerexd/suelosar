import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/repositories/sync_aware_local_repository.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';

void main() {
  test(
    'persistent queue preserves ten thousand ordered operations',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      for (final count in const <int>[1000, 5000, 10000]) {
        final queue = PersistentSyncQueue(storageKey: 'stress.queue.$count');
        final operations = List<SyncOperation>.generate(
          count,
          _operation,
          growable: false,
        );

        await queue.enqueueAll(operations);

        final restored = await queue.readAll();
        expect(restored, hasLength(count));
        expect(restored.first.operationId, operations.first.operationId);
        expect(restored.last.operationId, operations.last.operationId);
        expect(
          (await queue.takeBatch(50)).map((item) => item.operationId),
          operations.take(50).map((item) => item.operationId),
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'concurrent writes are serialized without dropping operations',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final queue = PersistentSyncQueue(storageKey: 'stress.queue.concurrent');
      final operations = List<SyncOperation>.generate(
        1000,
        _operation,
        growable: false,
      );

      await Future.wait(
        operations
            .map((operation) => queue.enqueue(operation))
            .toList(growable: false),
      );

      final restored = await queue.readAll();
      expect(restored, hasLength(operations.length));
      expect(
        restored.map((item) => item.operationId).toSet(),
        operations.map((item) => item.operationId).toSet(),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'repository batches ten thousand local changes',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final connectivity = ConnectivityService();
      final queue = PersistentSyncQueue(storageKey: 'stress.repository.10000');
      final engine = SyncEngine(
        queue: queue,
        connectivity: connectivity,
        logger: SyncLogger(sink: (_) {}),
      );
      final repository = SyncAwareLocalRepository(
        engine: engine,
        logger: SyncLogger(sink: (_) {}),
      );
      await engine.start();
      final markers = List<PersonalMarker>.generate(
        10000,
        (index) => PersonalMarker(
          id: 'marker-$index',
          uuid: '20000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
          latitude: -34 - index / 100000,
          longitude: -58 - index / 100000,
          name: 'Marcador $index',
          description: '',
          createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
        ),
        growable: false,
      );

      await repository.saveMarkers(markers);
      await _waitForQueueLength(queue, markers.length);
      expect(await queue.readAll(), hasLength(markers.length));

      await engine.dispose();
      await connectivity.dispose();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

SyncOperation _operation(int index) => SyncOperation(
  operationId: '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  uuid: '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  entityType: SyncEntityType.marker,
  operationType: SyncOperationType.create,
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
  retryCount: 0,
  payloadReference: 'marker:$index',
);

Future<void> _waitForQueueLength(
  PersistentSyncQueue queue,
  int expected,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if ((await queue.readAll()).length == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Queue did not reach $expected operations.');
}
