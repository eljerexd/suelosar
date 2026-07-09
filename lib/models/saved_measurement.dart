import 'package:latlong2/latlong.dart';

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

class SavedMeasurement {
  const SavedMeasurement({
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
  });

  static const String storageKey = 'gis.saved_measurements';

  final String id;
  final SavedMeasurementType type;
  final String name;
  final List<LatLng> geometry;
  final DateTime createdAt;
  final double? distanceMeters;
  final double? areaSquareMeters;
  final double? perimeterMeters;
  final bool isVisible;
  final String colorId;

  SavedMeasurement copyWith({String? name, bool? isVisible, String? colorId}) {
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
  };

  factory SavedMeasurement.fromJson(Map<String, Object?> json) {
    final rawGeometry = json['geometry'] as List<dynamic>? ?? const [];
    return SavedMeasurement(
      id: json['id']?.toString() ?? '',
      type: SavedMeasurementType.fromId(json['type']),
      name: json['name']?.toString() ?? '',
      geometry: [
        for (final rawPoint in rawGeometry)
          if (rawPoint is Map)
            LatLng(
              (rawPoint['latitude'] as num).toDouble(),
              (rawPoint['longitude'] as num).toDouble(),
            ),
      ],
      createdAt: DateTime.parse(json['createdAt'] as String),
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      areaSquareMeters: (json['areaSquareMeters'] as num?)?.toDouble(),
      perimeterMeters: (json['perimeterMeters'] as num?)?.toDouble(),
      isVisible: json['isVisible'] as bool? ?? true,
      colorId: switch (json['color']) {
        'orange' => 'orange',
        'red' => 'red',
        _ => 'blue',
      },
    );
  }
}
