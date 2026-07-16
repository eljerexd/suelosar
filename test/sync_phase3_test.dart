import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/repositories/sync_aware_local_repository.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/settings_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_backend_adapter.dart';
import 'package:suelosar/sync/sync_coordinator.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_state.dart';

void main() {
  test('queued marker changes wake the coordinator immediately', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.phase3.wakeup.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final repository = SyncAwareLocalRepository(
      engine: engine,
      logger: SyncLogger(sink: (_) {}),
    );
    final backend = _FakeSyncBackend(
      downloadDelay: const Duration(milliseconds: 100),
    );
    final coordinator = SyncCoordinator(
      engine: engine,
      backend: backend,
      logger: SyncLogger(sink: (_) {}),
      pollInterval: const Duration(days: 1),
    );
    await engine.start();
    await coordinator.start();

    final marker = PersonalMarker(
      id: 'marker-immediate',
      latitude: -34.9,
      longitude: -57.9,
      name: 'Immediate',
      description: '',
      createdAt: DateTime.utc(2026, 7, 16),
      syncState: SyncState.pendingUpload,
    );
    await repository.saveMarkers([marker]);

    await _waitForUpload(backend, marker.uuid);
    expect(await queue.readAll(), isEmpty);

    await coordinator.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  test(
    'polling uploads queued changes and merges the newest remote record',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.instance.initialize();
      final connectivity = ConnectivityService();
      final queue = PersistentSyncQueue(storageKey: 'test.phase3.queue');
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

      final local = PersonalMarker(
        id: 'marker-1',
        latitude: -34.9,
        longitude: -57.9,
        name: 'Local',
        description: '',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        syncState: SyncState.pendingUpload,
      );
      await repository.saveMarkers([local]);
      await _waitForQueue(queue, 1);

      final remotePayload = local
          .copyWith(name: 'Remoto', updatedAt: DateTime.utc(2026, 1, 3))
          .toJson();
      final backend = _FakeSyncBackend(
        downloadBatch: SyncDownloadBatch(
          changes: [
            {
              'entityType': 'marker',
              'uuid': local.uuid,
              'deviceUuid': '22222222-2222-4222-8222-222222222222',
              'createdAt': local.createdAt.toIso8601String(),
              'updatedAt': DateTime.utc(2026, 1, 3).toIso8601String(),
              'deletedAt': null,
              'syncState': 'synced',
              'payload': remotePayload,
            },
          ],
          nextCursor: '{"markers":{"updatedAt":"2026-01-03T00:00:00Z"}}',
        ),
      );
      final coordinator = SyncCoordinator(
        engine: engine,
        backend: backend,
        logger: SyncLogger(sink: (_) {}),
        pollInterval: const Duration(days: 1),
      );

      await coordinator.synchronizeNow();

      expect(backend.uploaded.single.operation.uuid, local.uuid);
      expect(await queue.readAll(), isEmpty);
      expect(engine.status.value.name, 'completed');
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getStringList(PersonalMarker.storageKey)!;
      final merged = PersonalMarker.fromJson(
        Map<String, Object?>.from(jsonDecode(stored.single) as Map),
      );
      expect(merged.name, 'Remoto');
      expect(merged.syncState, SyncState.synced);
      expect(
        preferences.getString(SyncCoordinator.cursorStorageKey),
        backend.downloadBatch.nextCursor,
      );

      await coordinator.dispose();
      await engine.dispose();
      await connectivity.dispose();
    },
  );

  test(
    'failed backend calls keep operations queued and schedule retry',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final connectivity = ConnectivityService();
      final queue = PersistentSyncQueue(storageKey: 'test.phase3.retry.queue');
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
      await repository.saveMarkers([
        PersonalMarker(
          id: 'marker-retry',
          latitude: -35,
          longitude: -58,
          name: 'Pendiente',
          description: '',
          createdAt: DateTime.utc(2026, 2, 1),
          syncState: SyncState.pendingUpload,
        ),
      ]);
      await _waitForQueue(queue, 1);
      final coordinator = SyncCoordinator(
        engine: engine,
        backend: _FakeSyncBackend(error: StateError('offline')),
        logger: SyncLogger(sink: (_) {}),
        pollInterval: const Duration(days: 1),
      );

      await coordinator.synchronizeNow();

      final queued = await queue.readAll();
      expect(queued, hasLength(1));
      expect(queued.single.retryCount, 1);
      expect(connectivity.status, ConnectivityStatus.offline);

      await coordinator.dispose();
      await engine.dispose();
      await connectivity.dispose();
    },
  );
}

class _FakeSyncBackend implements SyncBackendAdapter {
  _FakeSyncBackend({
    this.downloadBatch = const SyncDownloadBatch(changes: [], nextCursor: null),
    this.error,
    this.downloadDelay = Duration.zero,
  });

  final SyncDownloadBatch downloadBatch;
  final Object? error;
  final Duration downloadDelay;
  final List<PreparedSyncUpload> uploaded = [];

  @override
  Future<void> upload(List<PreparedSyncUpload> batch) async {
    if (error case final error?) throw error;
    uploaded.addAll(batch);
  }

  @override
  Future<SyncDownloadBatch> download(SyncDownloadRequest request) async {
    if (error case final error?) throw error;
    if (downloadDelay > Duration.zero) {
      await Future<void>.delayed(downloadDelay);
    }
    return downloadBatch;
  }
}

Future<void> _waitForQueue(PersistentSyncQueue queue, int length) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if ((await queue.readAll()).length == length) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Queue did not reach $length operations.');
}

Future<void> _waitForUpload(_FakeSyncBackend backend, String uuid) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (backend.uploaded.any((item) => item.operation.uuid == uuid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Marker $uuid was not uploaded automatically.');
}
