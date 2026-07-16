import 'package:latlong2/latlong.dart';

import '../sync/sync_entity.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';

enum SavedMeasurementType {
  distance,
  area;

  static SavedMeasurementType fromId(Object? value) {
    return values.firstWhere(
      (type) => type.name == value,
      orElse: () => distance,
    );
  }
}

class SavedMeasurement implements SyncEntity {
  SavedMeasurement({
    required this.id,
    required this.type,
    required this.name,
    required this.geometry,
    required this.createdAt,
    this.distanceMeters,
    this.areaSquareMeters,
    this.perimeterMeters,
    this.isVisible = true,
    this.colorId = 'blue',
    String? uuid,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.local,
  }) : uuid = uuid ?? UuidV4.generate(),
       updatedAt = updatedAt ?? createdAt;

  static const String storageKey = 'gis.saved_measurements';

  final String id;
  final SavedMeasurementType type;
  final String name;
  final List<LatLng> geometry;
  @override
  final DateTime createdAt;
  final double? distanceMeters;
  final double? areaSquareMeters;
  final double? perimeterMeters;
  final bool isVisible;
  final String colorId;
  @override
  final String uuid;
  @override
  final DateTime updatedAt;
  @override
  final DateTime? deletedAt;
  @override
  final SyncState syncState;

  SavedMeasurement copyWith({
    String? name,
    bool? isVisible,
    String? colorId,
    DateTime? updatedAt,
    DateTime? deletedAt,
    SyncState? syncState,
  }) {
    return SavedMeasurement(
      id: id,
      type: type,
      name: name ?? this.name,
      geometry: geometry,
      createdAt: createdAt,
      distanceMeters: distanceMeters,
      areaSquareMeters: areaSquareMeters,
      perimeterMeters: perimeterMeters,
      isVisible: isVisible ?? this.isVisible,
      colorId: colorId ?? this.colorId,
      uuid: uuid,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      syncState: syncState ?? SyncState.pendingUpload,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'type': type.name,
    'name': name,
    'geometry': [
      for (final point in geometry)
        <String, double>{
          'latitude': point.latitude,
          'longitude': point.longitude,
        },
    ],
    'createdAt': createdAt.toIso8601String(),
    'distanceMeters': distanceMeters,
    'areaSquareMeters': areaSquareMeters,
    'perimeterMeters': perimeterMeters,
    'isVisible': isVisible,
    'color': colorId,
    'uuid': uuid,
    'updatedAt': updatedAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'syncState': syncState.name,
  };

  factory SavedMeasurement.fromJson(Map<String, Object?> json) {
    final rawGeometry = json['geometry'] as List<dynamic>? ?? const [];
    final createdAt =
        parseSyncDate(json['createdAt']) ?? DateTime.now().toUtc();
    final storedUuid = json['uuid']?.toString() ?? '';
    return SavedMeasurement(
      id: json['id']?.toString() ?? '',
      type: SavedMeasurementType.fromId(json['type']),
      name: json['name']?.toString() ?? '',
      geometry: rawGeometry
          .map(_latLngFromJson)
          .whereType<LatLng>()
          .toList(growable: false),
      createdAt: createdAt,
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      areaSquareMeters: (json['areaSquareMeters'] as num?)?.toDouble(),
      perimeterMeters: (json['perimeterMeters'] as num?)?.toDouble(),
      isVisible: json['isVisible'] as bool? ?? true,
      colorId: switch (json['color']) {
        'orange' => 'orange',
        'red' => 'red',
        _ => 'blue',
      },
      uuid: UuidV4.isValid(storedUuid) ? storedUuid : UuidV4.generate(),
      updatedAt: parseSyncDate(json['updatedAt']) ?? createdAt,
      deletedAt: parseSyncDate(json['deletedAt']),
      syncState: SyncState.fromJson(json['syncState']),
    );
  }
}

LatLng? _latLngFromJson(Object? rawPoint) {
  if (rawPoint is! Map) return null;
  final rawLatitude = rawPoint['latitude'];
  final rawLongitude = rawPoint['longitude'];
  if (rawLatitude is! num || rawLongitude is! num) return null;

  final latitude = rawLatitude.toDouble();
  final longitude = rawLongitude.toDouble();
  if (!latitude.isFinite ||
      latitude.isNaN ||
      !longitude.isFinite ||
      longitude.isNaN) {
    return null;
  }
  return LatLng(latitude, longitude);
}
