import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/repositories/sync_aware_local_repository.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/settings_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_local_merge_store.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';
import 'package:suelosar/sync/sync_payload_policy.dart';
import 'package:suelosar/sync/sync_state.dart';

void main() {
  testWidgets('soil polygon visibility is persisted only on this device', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyRepository())),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Capas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Polígonos de suelo'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('gis.show_soil_polygons'), isFalse);
    expect(preferences.getString('settings.sync_record'), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyRepository())),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final state = tester.state(find.byType(GisMapScreen)) as dynamic;
    expect(state.showSoilPolygons, isFalse);
  });

  test('remote measurement merge preserves local visibility', () async {
    final local = _measurement(isVisible: false);
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [jsonEncode(local.toJson())],
    });
    final remote = local.copyWith(
      name: 'Nombre remoto',
      updatedAt: DateTime.utc(2026, 7, 2),
      syncState: SyncState.synced,
    );
    final remotePayload = remote.toJson()..['isVisible'] = true;

    await const SyncLocalMergeStore().mergeRemoteChanges([
      {
        'entityType': SyncEntityType.measurement.name,
        'uuid': remote.uuid,
        'createdAt': remote.createdAt.toIso8601String(),
        'updatedAt': remote.updatedAt.toIso8601String(),
        'deletedAt': null,
        'syncState': SyncState.synced.name,
        'payload': remotePayload,
      },
    ]);

    final preferences = await SharedPreferences.getInstance();
    final stored = SavedMeasurement.fromJson(
      Map<String, Object?>.from(
        jsonDecode(
              preferences.getStringList(SavedMeasurement.storageKey)!.single,
            )
            as Map,
      ),
    );
    expect(stored.name, 'Nombre remoto');
    expect(stored.isVisible, isFalse);
    expect(
      SyncPayloadPolicy.forUpload(SyncEntityType.measurement, stored.toJson()),
      isNot(contains('isVisible')),
    );
  });

  test('legacy remote settings cannot change local preferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings.show_zoom_level': false,
    });
    await SettingsService.instance.initialize();

    await const SyncLocalMergeStore().mergeRemoteChanges([
      {
        'entityType': SyncEntityType.settings.name,
        'uuid': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'createdAt': '2026-07-01T00:00:00.000Z',
        'updatedAt': '2026-07-02T00:00:00.000Z',
        'deletedAt': null,
        'syncState': SyncState.synced.name,
        'payload': {
          'values': {'showZoomLevel': true},
        },
      },
    ]);

    final preferences = await SharedPreferences.getInstance();
    expect(SettingsService.instance.showZoomLevel, isFalse);
    expect(preferences.getBool('settings.show_zoom_level'), isFalse);
  });

  test(
    'visibility-only measurement changes never enter the sync queue',
    () async {
      final measurement = _measurement(isVisible: true);
      SharedPreferences.setMockInitialValues(<String, Object>{
        SavedMeasurement.storageKey: [jsonEncode(measurement.toJson())],
      });
      final connectivity = ConnectivityService();
      final queue = PersistentSyncQueue(
        storageKey: 'test.local.visibility.queue',
      );
      final engine = SyncEngine(
        queue: queue,
        connectivity: connectivity,
        logger: SyncLogger(sink: (_) {}),
      );
      final repository = SyncAwareLocalRepository(
        engine: engine,
        logger: SyncLogger(sink: (_) {}),
      );

      await repository.saveMeasurements([
        measurement.withLocalVisibility(false),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await queue.readAll(), isEmpty);
      await engine.dispose();
      await connectivity.dispose();
    },
  );

  test(
    'legacy synchronized settings and queued operations are discarded',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.sync_record': jsonEncode({
          'values': {'reduceAnimations': true},
          'uuid': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'createdAt': '2026-07-01T00:00:00.000Z',
          'updatedAt': '2026-07-01T00:00:00.000Z',
          'deletedAt': null,
          'syncState': 'pendingUpload',
        }),
      });
      final connectivity = ConnectivityService();
      final queue = PersistentSyncQueue(
        storageKey: 'test.legacy.settings.queue',
      );
      final engine = SyncEngine(
        queue: queue,
        connectivity: connectivity,
        logger: SyncLogger(sink: (_) {}),
      );
      await engine.recordLocalChange(
        entityType: SyncEntityType.settings,
        operationType: SyncOperationType.update,
        uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        payload: const {'reduceAnimations': true},
      );

      await SettingsService.instance.initialize();
      await engine.start();

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('settings.sync_record'), isNull);
      expect(await queue.readAll(), isEmpty);
      expect(
        SyncPayloadPolicy.synchronizedEntityTypes,
        equals({
          SyncEntityType.marker,
          SyncEntityType.measurement,
          SyncEntityType.favorite,
        }),
      );
      await engine.dispose();
      await connectivity.dispose();
    },
  );
}

SavedMeasurement _measurement({required bool isVisible}) => SavedMeasurement(
  id: 'measurement-local-visibility',
  type: SavedMeasurementType.area,
  name: 'Lote',
  geometry: const [
    LatLng(-36.5, -60),
    LatLng(-36.5, -59.9),
    LatLng(-36.4, -59.9),
  ],
  createdAt: DateTime.utc(2026, 7, 1),
  updatedAt: DateTime.utc(2026, 7, 1),
  areaSquareMeters: 10000,
  perimeterMeters: 400,
  isVisible: isVisible,
  uuid: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  syncState: SyncState.synced,
);

class _EmptyRepository implements GisRepository {
  const _EmptyRepository();

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 7,
    maxZoom: 14,
    centerLatitude: -36.5,
    centerLongitude: -60,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async => GisLayer(
    id: '${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
    name: 'empty',
    features: const [],
  );

  @override
  Future<void> close() async {}
}
