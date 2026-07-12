import 'package:latlong2/latlong.dart';

import '../models/saved_measurement.dart';

enum MeasurementExportType { distance, area }

class MeasurementExportCoordinate {
  const MeasurementExportCoordinate({
    required this.latitude,
    required this.longitude,
  });

  factory MeasurementExportCoordinate.fromLatLng(LatLng point) {
    return MeasurementExportCoordinate(
      latitude: point.latitude,
      longitude: point.longitude,
    );
  }

  final double latitude;
  final double longitude;

  Map<String, double> toJson() => <String, double>{
    'latitude': latitude,
    'longitude': longitude,
  };
}

class MeasurementExportData {
  const MeasurementExportData({
    required this.type,
    required this.coordinates,
    required this.createdAt,
    this.id,
    this.title,
    this.notes,
    this.crs = 'EPSG:4326',
    this.color,
    this.distanceMeters,
    this.areaSquareMeters,
    this.perimeterMeters,
  });

  final MeasurementExportType type;
  final List<MeasurementExportCoordinate> coordinates;
  final DateTime createdAt;
  final String? id;
  final String? title;
  final String? notes;
  final String crs;
  final String? color;
  final double? distanceMeters;
  final double? areaSquareMeters;
  final double? perimeterMeters;

  bool get isArea => type == MeasurementExportType.area;
  bool get isDistance => type == MeasurementExportType.distance;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'type': type.name,
    'title': title,
    'notes': notes,
    'crs': crs,
    'color': color,
    'createdAt': createdAt.toIso8601String(),
    'distanceMeters': distanceMeters,
    'areaSquareMeters': areaSquareMeters,
    'perimeterMeters': perimeterMeters,
    'coordinates': [for (final coordinate in coordinates) coordinate.toJson()],
  };
}

extension MeasurementExportTypeMapper on SavedMeasurementType {
  MeasurementExportType toExportType() {
    return switch (this) {
      SavedMeasurementType.distance => MeasurementExportType.distance,
      SavedMeasurementType.area => MeasurementExportType.area,
    };
  }
}
