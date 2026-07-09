import 'package:latlong2/latlong.dart';

import '../models/saved_measurement.dart';
import 'measurement_export_models.dart';

class MeasurementExportService {
  const MeasurementExportService();

  MeasurementExportData fromSavedMeasurement(
    SavedMeasurement measurement, {
    String? notes,
    String crs = 'EPSG:4326',
  }) {
    return MeasurementExportData(
      type: measurement.type.toExportType(),
      title: measurement.name.isEmpty ? null : measurement.name,
      notes: notes,
      crs: crs,
      createdAt: measurement.createdAt,
      coordinates: _coordinatesFromLatLng(measurement.geometry),
      distanceMeters: measurement.distanceMeters,
      areaSquareMeters: measurement.areaSquareMeters,
      perimeterMeters: measurement.perimeterMeters,
    );
  }

  MeasurementExportData fromCurrentMeasurement({
    required SavedMeasurementType type,
    required List<LatLng> geometry,
    required DateTime createdAt,
    String? title,
    String? notes,
    String crs = 'EPSG:4326',
    double? distanceMeters,
    double? areaSquareMeters,
    double? perimeterMeters,
  }) {
    return MeasurementExportData(
      type: type.toExportType(),
      title: title,
      notes: notes,
      crs: crs,
      createdAt: createdAt,
      coordinates: _coordinatesFromLatLng(geometry),
      distanceMeters: distanceMeters,
      areaSquareMeters: areaSquareMeters,
      perimeterMeters: perimeterMeters,
    );
  }

  List<MeasurementExportCoordinate> _coordinatesFromLatLng(
    List<LatLng> geometry,
  ) {
    return List<MeasurementExportCoordinate>.unmodifiable(
      geometry.map(MeasurementExportCoordinate.fromLatLng),
    );
  }
}
