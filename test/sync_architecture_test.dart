import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/app_settings_sync_record.dart';
import 'package:suelosar/models/favorite_soil_feature.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/services/device_identity_service.dart';
import 'package:suelosar/services/local_sync_migration_service.dart';
import 'package:suelosar/services/settings_service.dart';
import 'package:suelosar/sync/sync_state.dart';
import 'package:suelosar/sync/uuid_v4.dart';

void main() {
  test('UUID generator produces unique RFC 4122 version 4 identifiers', () {
    final values = {
      for (var index = 0; index < 100; index++) UuidV4.generate(),
    };
    expect(values, hasLength(100));
    expect(values.every(UuidV4.isValid), isTrue);
  });

  test('device identity is generated once and persisted', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DeviceIdentityService.instance.initialize();
    final first = DeviceIdentityService.instance.deviceUuid;
    expect(UuidV4.isValid(first), isTrue);

    await DeviceIdentityService.instance.initialize();
    expect(DeviceIdentityService.instance.deviceUuid, first);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(DeviceIdentityService.storageKey), first);
  });

  test('legacy local entities gain sync metadata without data loss', () async {
    const markerJson = <String, Object?>{
      'id': 'legacy-marker',
      'latitude': -36.5,
      'longitude': -60.0,
      'name': 'Calicata norte',
      'description': 'Perfil 1',
      'category': 'soil_pit',
      'createdAt': '2025-01-02T03:04:05.000Z',
    };
    const measurementJson = <String, Object?>{
      'id': 'legacy-measurement',
      'type': 'area',
      'name': 'Lote 1',
      'geometry': <Object?>[
        <String, double>{'latitude': -36.5, 'longitude': -60.0},
        <String, double>{'latitude': -36.4, 'longitude': -60.0},
        <String, double>{'latitude': -36.4, 'longitude': -59.9},
      ],
      'createdAt': '2025-02-03T04:05:06.000Z',
      'areaSquareMeters': 10000.0,
      'perimeterMeters': 400.0,
      'isVisible': true,
      'color': 'orange',
    };
    const favoriteJson = <String, Object?>{
      'id': 'legacy-favorite',
      'unitName': 'Unidad AC6',
      'unitSymbol': 'AC6',
      'soilSeries': <String>['Serie A'],
      'pdfIdentifier': 'serie-a.pdf',
    };
    const malformed = '{not-json';
    SharedPreferences.setMockInitialValues(<String, Object>{
      PersonalMarker.storageKey: <String>[jsonEncode(markerJson), malformed],
      SavedMeasurement.storageKey: <String>[jsonEncode(measurementJson)],
      FavoriteSoilFeature.storageKey: <String>[jsonEncode(favoriteJson)],
    });

    await const LocalSyncMigrationService().migrate();
    final preferences = await SharedPreferences.getInstance();
    final markerRecords = preferences.getStringList(PersonalMarker.storageKey)!;
    final marker = PersonalMarker.fromJson(
      Map<String, Object?>.from(jsonDecode(markerRecords.first) as Map),
    );
    final measurement = SavedMeasurement.fromJson(
      Map<String, Object?>.from(
        jsonDecode(
              preferences.getStringList(SavedMeasurement.storageKey)!.single,
            )
            as Map,
      ),
    );
    final favorite = FavoriteSoilFeature.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(
              preferences.getStringList(FavoriteSoilFeature.storageKey)!.single,
            )
            as Map,
      ),
    );

    expect(marker.id, markerJson['id']);
    expect(marker.name, markerJson['name']);
    expect(UuidV4.isValid(marker.uuid), isTrue);
    expect(marker.updatedAt, marker.createdAt);
    expect(marker.syncState, SyncState.local);
    expect(markerRecords.last, malformed);

    expect(measurement.id, measurementJson['id']);
    expect(measurement.geometry, hasLength(3));
    expect(measurement.colorId, 'orange');
    expect(UuidV4.isValid(measurement.uuid), isTrue);
    expect(measurement.updatedAt, measurement.createdAt);

    expect(favorite.id, favoriteJson['id']);
    expect(favorite.unitSymbol, 'AC6');
    expect(UuidV4.isValid(favorite.uuid), isTrue);

    final uuidsBeforeSecondRun = <String>[
      marker.uuid,
      measurement.uuid,
      favorite.uuid,
    ];
    await const LocalSyncMigrationService().migrate();
    final markerAfter = PersonalMarker.fromJson(
      Map<String, Object?>.from(
        jsonDecode(preferences.getStringList(PersonalMarker.storageKey)!.first)
            as Map,
      ),
    );
    final measurementAfter = SavedMeasurement.fromJson(
      Map<String, Object?>.from(
        jsonDecode(
              preferences.getStringList(SavedMeasurement.storageKey)!.single,
            )
            as Map,
      ),
    );
    final favoriteAfter = FavoriteSoilFeature.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(
              preferences.getStringList(FavoriteSoilFeature.storageKey)!.single,
            )
            as Map,
      ),
    );
    expect(<String>[
      markerAfter.uuid,
      measurementAfter.uuid,
      favoriteAfter.uuid,
    ], uuidsBeforeSecondRun);
  });

  test('settings expose a persistent sync-ready snapshot', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.instance.initialize();
    final initial = SettingsService.instance.syncRecord;
    expect(initial, isNotNull);
    expect(UuidV4.isValid(initial!.uuid), isTrue);
    expect(initial.syncState, SyncState.local);

    await SettingsService.instance.setShowZoomLevel(false);
    final updated = SettingsService.instance.syncRecord!;
    expect(updated.uuid, initial.uuid);
    expect(updated.updatedAt.isAfter(initial.updatedAt), isTrue);
    expect(updated.syncState, SyncState.pendingUpload);
    expect(updated.values['showZoomLevel'], isFalse);

    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(AppSettingsSyncRecord.storageKey);
    expect(encoded, isNotNull);
    final restored = AppSettingsSyncRecord.fromJson(
      Map<String, dynamic>.from(jsonDecode(encoded!) as Map),
    );
    expect(restored.uuid, initial.uuid);
    expect(restored.values['showZoomLevel'], isFalse);
  });
}
