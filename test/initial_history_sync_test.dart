import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/app_settings_sync_record.dart';
import 'package:suelosar/models/favorite_soil_feature.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/settings_service.dart';
import 'package:suelosar/sync/initial_history_sync.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_backend_adapter.dart';
import 'package:suelosar/sync/sync_coordinator.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_local_merge_store.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';
import 'package:suelosar/sync/sync_state.dart';

const _groupUuid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  test(
    'bootstrap uploads existing history in batches and it can be downloaded',
    () async {
      final markers = List.generate(250, _marker);
      final measurements = List.generate(80, _measurement);
      final favorites = List.generate(35, _favorite);
      final settings = AppSettingsSyncRecord(
        values: const {'reduceAnimations': false},
        uuid: _uuid(9000),
        createdAt: DateTime.utc(2024),
        updatedAt: DateTime.utc(2024, 1, 2),
        syncState: SyncState.local,
      );
      await _seed(
        markers: markers,
        measurements: measurements,
        favorites: favorites,
        settings: settings,
      );
      final backend = _MemorySyncBackend();
      final harness = await _SyncHarness.start(backend, 'bootstrap.large');

      await harness.waitForBootstrap();

      expect(backend.rowsFor(SyncEntityType.marker), hasLength(250));
      expect(backend.rowsFor(SyncEntityType.measurement), hasLength(80));
      expect(backend.rowsFor(SyncEntityType.favorite), hasLength(35));
      expect(backend.rowsFor(SyncEntityType.settings), hasLength(1));
      expect(backend.uploadBatchSizes, everyElement(lessThanOrEqualTo(50)));
      expect(harness.initialHistory.progress.value.markers.completed, 250);
      expect(harness.initialHistory.progress.value.measurements.completed, 80);
      expect(harness.initialHistory.progress.value.favorites.completed, 35);
      expect(harness.initialHistory.progress.value.settings.completed, 1);

      // Simulate an empty second device consuming the same cloud snapshot.
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(PersonalMarker.storageKey, []);
      await preferences.setStringList(SavedMeasurement.storageKey, []);
      await preferences.setStringList(FavoriteSoilFeature.storageKey, []);
      await const SyncLocalMergeStore().mergeRemoteChanges(backend.allChanges);
      expect(
        preferences.getStringList(PersonalMarker.storageKey),
        hasLength(250),
      );
      expect(
        preferences.getStringList(SavedMeasurement.storageKey),
        hasLength(80),
      );
      expect(
        preferences.getStringList(FavoriteSoilFeature.storageKey),
        hasLength(35),
      );

      await harness.dispose();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('completed bootstrap does not upload the same history twice', () async {
    final marker = _marker(1);
    await _seed(markers: [marker]);
    final backend = _MemorySyncBackend();
    final first = await _SyncHarness.start(backend, 'bootstrap.once.first');
    await first.waitForBootstrap();
    expect(backend.uploadAttempts, hasLength(1));
    await first.dispose();

    final second = await _SyncHarness.start(backend, 'bootstrap.once.second');
    await _waitUntil(() async {
      final operations = await second.engine.queue.readAll();
      return operations.isEmpty &&
          second.engine.status.value.name == 'completed';
    });

    expect(backend.uploadAttempts, hasLength(1));
    await second.dispose();
  });

  test('bootstrap uploads only a local entity missing remotely', () async {
    final markers = [_marker(1), _marker(2), _marker(3)];
    await _seed(markers: markers);
    final backend = _MemorySyncBackend(
      initialChanges: [
        _remoteChange(SyncEntityType.marker, markers[0].toJson()),
        _remoteChange(SyncEntityType.marker, markers[1].toJson()),
      ],
    );
    final harness = await _SyncHarness.start(backend, 'bootstrap.missing');

    await harness.waitForBootstrap();

    expect(backend.uploadAttempts, hasLength(1));
    expect(backend.uploadAttempts.single.operation.uuid, markers[2].uuid);
    await harness.dispose();
  });

  test('newer remote entity wins without a bootstrap upload', () async {
    final local = _marker(
      7,
      updatedAt: DateTime.utc(2025, 1, 1),
      syncState: SyncState.pendingUpload,
    );
    final remote = local.copyWith(
      name: 'Remoto',
      updatedAt: DateTime.utc(2025, 1, 2),
      syncState: SyncState.synced,
    );
    await _seed(markers: [local]);
    final backend = _MemorySyncBackend(
      initialChanges: [_remoteChange(SyncEntityType.marker, remote.toJson())],
    );
    final harness = await _SyncHarness.start(backend, 'bootstrap.remote.newer');

    await harness.waitForBootstrap();

    expect(backend.uploadAttempts, isEmpty);
    final stored = await _storedMarker(local.uuid);
    expect(stored.name, 'Remoto');
    expect(stored.updatedAt, remote.updatedAt);
    expect(stored.syncState, SyncState.synced);
    await harness.dispose();
  });

  test('newer local entity wins and is uploaded', () async {
    final local = _marker(8, updatedAt: DateTime.utc(2025, 1, 2));
    final remote = local.copyWith(
      name: 'Remoto anterior',
      updatedAt: DateTime.utc(2025, 1, 1),
      syncState: SyncState.synced,
    );
    await _seed(markers: [local]);
    final backend = _MemorySyncBackend(
      initialChanges: [_remoteChange(SyncEntityType.marker, remote.toJson())],
    );
    final harness = await _SyncHarness.start(backend, 'bootstrap.local.newer');

    await harness.waitForBootstrap();

    expect(backend.uploadAttempts, hasLength(1));
    final cloud = backend.rowsFor(SyncEntityType.marker).single;
    expect(cloud['updatedAt'], local.updatedAt.toIso8601String());
    expect((cloud['payload'] as Map)['name'], local.name);
    await harness.dispose();
  });
}

class _SyncHarness {
  _SyncHarness({
    required this.connectivity,
    required this.engine,
    required this.coordinator,
    required this.initialHistory,
  });

  final ConnectivityService connectivity;
  final SyncEngine engine;
  final SyncCoordinator coordinator;
  final InitialHistorySync initialHistory;

  static Future<_SyncHarness> start(
    _MemorySyncBackend backend,
    String queueKey,
  ) async {
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final engine = SyncEngine(
      queue: PersistentSyncQueue(storageKey: queueKey),
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final initialHistory = InitialHistorySync(
      engine: engine,
      backend: backend,
      logger: SyncLogger(sink: (_) {}),
    );
    final coordinator = SyncCoordinator(
      engine: engine,
      backend: backend,
      initialHistorySync: initialHistory,
      logger: SyncLogger(sink: (_) {}),
      pollInterval: const Duration(days: 1),
    );
    await engine.start();
    await coordinator.start();
    return _SyncHarness(
      connectivity: connectivity,
      engine: engine,
      coordinator: coordinator,
      initialHistory: initialHistory,
    );
  }

  Future<void> waitForBootstrap() => _waitUntil(() async {
    final operations = await engine.queue.readAll();
    return operations.isEmpty &&
        initialHistory.progress.value.status ==
            InitialHistorySyncStatus.completed;
  });

  Future<void> dispose() async {
    await coordinator.dispose();
    await engine.dispose();
    await connectivity.dispose();
  }
}

class _MemorySyncBackend implements SyncBackendAdapter {
  _MemorySyncBackend({List<Map<String, Object?>> initialChanges = const []}) {
    for (final change in initialChanges) {
      final type = SyncEntityType.values.byName(
        change['entityType']!.toString(),
      );
      _rows[_key(type, change['uuid']!.toString())] = Map<String, Object?>.from(
        change,
      );
    }
  }

  final Map<String, Map<String, Object?>> _rows = {};
  final List<PreparedSyncUpload> uploadAttempts = [];
  final List<int> uploadBatchSizes = [];

  Iterable<Map<String, Object?>> get allChanges =>
      _rows.values.map(Map<String, Object?>.from);

  List<Map<String, Object?>> rowsFor(SyncEntityType type) => _rows.values
      .where((row) => row['entityType'] == type.name)
      .toList(growable: false);

  @override
  Future<void> upload(List<PreparedSyncUpload> batch) async {
    uploadBatchSizes.add(batch.length);
    uploadAttempts.addAll(batch);
    for (final item in batch) {
      final incoming = _remoteChange(item.operation.entityType, item.payload);
      final key = _key(item.operation.entityType, item.operation.uuid);
      final current = _rows[key];
      final incomingDate = DateTime.parse(incoming['updatedAt']!.toString());
      final currentDate = DateTime.tryParse(
        current?['updatedAt']?.toString() ?? '',
      );
      if (currentDate == null || !incomingDate.isBefore(currentDate)) {
        _rows[key] = incoming;
      }
    }
  }

  @override
  Future<SyncDownloadBatch> download(SyncDownloadRequest request) async {
    final ordered = _rows.values.toList(growable: false)
      ..sort((left, right) {
        final date = left['updatedAt'].toString().compareTo(
          right['updatedAt'].toString(),
        );
        return date != 0
            ? date
            : left['uuid'].toString().compareTo(right['uuid'].toString());
      });
    final offset = int.tryParse(request.cursor ?? '') ?? 0;
    if (offset >= ordered.length) {
      return SyncDownloadBatch(changes: const [], nextCursor: '$offset');
    }
    final end = (offset + request.limit).clamp(0, ordered.length);
    return SyncDownloadBatch(
      changes: ordered
          .sublist(offset, end)
          .map(Map<String, Object?>.from)
          .toList(growable: false),
      nextCursor: '$end',
    );
  }

  String _key(SyncEntityType type, String uuid) => '${type.name}:$uuid';
}

Future<void> _seed({
  List<PersonalMarker> markers = const [],
  List<SavedMeasurement> measurements = const [],
  List<FavoriteSoilFeature> favorites = const [],
  AppSettingsSyncRecord? settings,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    InitialHistorySync.groupStorageKey: _groupUuid,
    PersonalMarker.storageKey: markers
        .map((item) => jsonEncode(item.toJson()))
        .toList(),
    SavedMeasurement.storageKey: measurements
        .map((item) => jsonEncode(item.toJson()))
        .toList(),
    FavoriteSoilFeature.storageKey: favorites
        .map((item) => jsonEncode(item.toJson()))
        .toList(),
    if (settings != null)
      AppSettingsSyncRecord.storageKey: jsonEncode(settings.toJson()),
  });
  await SettingsService.instance.initialize();
}

PersonalMarker _marker(
  int index, {
  DateTime? updatedAt,
  SyncState syncState = SyncState.local,
}) {
  final createdAt = DateTime.utc(2024, 1, 1).add(Duration(minutes: index));
  return PersonalMarker(
    id: 'marker-$index',
    latitude: -34.0 - index / 10000,
    longitude: -58.0 - index / 10000,
    name: 'Marcador $index',
    description: 'Histórico',
    createdAt: createdAt,
    uuid: _uuid(index),
    updatedAt: updatedAt ?? createdAt,
    syncState: syncState,
  );
}

SavedMeasurement _measurement(int index) {
  final createdAt = DateTime.utc(2024, 2, 1).add(Duration(minutes: index));
  return SavedMeasurement(
    id: 'measurement-$index',
    type: index.isEven
        ? SavedMeasurementType.area
        : SavedMeasurementType.distance,
    name: 'Medición $index',
    geometry: [
      LatLng(-34 - index / 10000, -58),
      LatLng(-34 - index / 10000, -58.001),
      if (index.isEven) LatLng(-34.001 - index / 10000, -58.001),
    ],
    createdAt: createdAt,
    distanceMeters: index.isOdd ? 100 + index.toDouble() : null,
    areaSquareMeters: index.isEven ? 10000 + index.toDouble() : null,
    perimeterMeters: index.isEven ? 400 + index.toDouble() : null,
    uuid: _uuid(1000 + index),
    updatedAt: createdAt,
    syncState: SyncState.local,
  );
}

FavoriteSoilFeature _favorite(int index) {
  final createdAt = DateTime.utc(2024, 3, 1).add(Duration(minutes: index));
  return FavoriteSoilFeature(
    id: 'favorite-$index',
    unitName: 'Unidad $index',
    unitSymbol: 'U$index',
    soilSeries: ['Serie $index'],
    pdfIdentifier: null,
    uuid: _uuid(2000 + index),
    createdAt: createdAt,
    updatedAt: createdAt,
    syncState: SyncState.local,
  );
}

Map<String, Object?> _remoteChange(
  SyncEntityType type,
  Map<String, Object?> payload,
) => <String, Object?>{
  'entityType': type.name,
  'uuid': payload['uuid'],
  'deviceUuid': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'createdAt': payload['createdAt'],
  'updatedAt': payload['updatedAt'],
  'deletedAt': payload['deletedAt'],
  'syncState': SyncState.synced.name,
  'payload': Map<String, Object?>.from(payload)
    ..['syncState'] = SyncState.synced.name,
};

Future<PersonalMarker> _storedMarker(String uuid) async {
  final preferences = await SharedPreferences.getInstance();
  final records = preferences.getStringList(PersonalMarker.storageKey)!;
  return records
      .map(
        (value) => PersonalMarker.fromJson(
          Map<String, Object?>.from(jsonDecode(value) as Map),
        ),
      )
      .firstWhere((marker) => marker.uuid == uuid);
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 1000; attempt++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for bootstrap synchronization.');
}

String _uuid(int value) =>
    '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';
