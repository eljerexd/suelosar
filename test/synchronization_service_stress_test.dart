import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/synchronization_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';

void main() {
  test(
    'idle synchronization service does not poll and decode its queue',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final connectivity = ConnectivityService();
      final queue = _CountingSyncQueue();
      await queue.enqueueAll(
        List<SyncOperation>.generate(
          10000,
          (index) => SyncOperation(
            operationId:
                '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
            uuid:
                '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
            entityType: SyncEntityType.marker,
            operationType: SyncOperationType.create,
            createdAt: DateTime.utc(2026, 1, 1),
            retryCount: 0,
            payloadReference: 'marker:$index',
          ),
          growable: false,
        ),
      );
      final engine = SyncEngine(
        queue: queue,
        connectivity: connectivity,
        logger: SyncLogger(sink: (_) {}),
      );
      final service = SynchronizationService(
        engine: engine,
        connectivity: connectivity,
        queue: queue,
        deviceDetailsLoader: () async =>
            const SynchronizationDeviceDetails.empty(),
      );

      await service.start();
      final readsAfterStart = queue.readCount;
      await Future<void>.delayed(const Duration(milliseconds: 2200));

      expect(queue.readCount, readsAfterStart);
      await service.refresh();
      expect(queue.readCount, readsAfterStart + 1);

      service.dispose();
      await engine.dispose();
      await connectivity.dispose();
    },
  );
}

class _CountingSyncQueue extends PersistentSyncQueue {
  _CountingSyncQueue() : super(storageKey: 'stress.service.queue');

  int readCount = 0;

  @override
  Future<List<SyncOperation>> readAll() {
    readCount++;
    return super.readAll();
  }
}
