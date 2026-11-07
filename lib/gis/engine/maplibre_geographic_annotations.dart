import 'dart:convert';

import 'package:latlong2/latlong.dart';

import 'maplibre_reference_basemap.dart';
import 'soil_map_engine.dart';

/// GeoJSON payloads for geographic annotations rendered by native style layers.
class MapLibreGeographicAnnotationData {
  const MapLibreGeographicAnnotationData._();

  static const emptyCollection = '{"type":"FeatureCollection","features":[]}';

  static String cityLabelImageId(
    String cityId, {
    bool enhancedForSoilPolygons = false,
  }) =>
      'suelosar-city-label-'
      '${enhancedForSoilPolygons ? 'enhanced-' : ''}'
      '${base64Url.encode(utf8.encode(cityId))}';

  static String administrativeLabelImageId(
    String cityId, {
    required bool enhancedForSoilPolygons,
  }) =>
      'suelosar-administrative-label-'
      '${enhancedForSoilPolygons ? 'enhanced-' : ''}'
      '${base64Url.encode(utf8.encode(cityId))}';

  static String personalMarkerImageId(String categoryId) =>
      'suelosar-personal-marker-$categoryId';

  static String cities(
    List<MapLibreReferenceCity> cities, {
    Set<String> enhancedAdministrativeProvinceIds = const <String>{},
  }) => jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (var index = 0; index < cities.length; index++)
        _pointFeature(
          id: cities[index].id,
          point: cities[index].point,
          properties: {
            'cityId': cities[index].id,
            'name': cities[index].name,
            'isPrimary': cities[index].isPrimary,
            'isAdministrative': cities[index].isAdministrative,
            'provinceId': cities[index].provinceId,
            'minZoomTier': cities[index].minZoomTier,
            'sortKey':
                (cities[index].isPrimary
                    ? 0
                    : cities[index].isAdministrative
                    ? 200000
                    : 100000) +
                index,
            'labelImage': cities[index].isAdministrative
                ? administrativeLabelImageId(
                    cities[index].id,
                    enhancedForSoilPolygons:
                        cities[index].provinceId == 'buenos_aires' &&
                        enhancedAdministrativeProvinceIds.contains(
                          cities[index].provinceId,
                        ),
                  )
                : cityLabelImageId(
                    cities[index].id,
                    enhancedForSoilPolygons:
                        cities[index].provinceId == 'buenos_aires' &&
                        enhancedAdministrativeProvinceIds.contains(
                          cities[index].provinceId,
                        ),
                  ),
          },
        ),
    ],
  });

  static String personalMarkers(List<SoilMapMarkerPin> markers) => jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (var index = 0; index < markers.length; index++)
        _pointFeature(
          id: markers[index].id,
          point: markers[index].point,
          properties: {
            ...markers[index].properties,
            'markerId': markers[index].id,
            'category': markers[index].categoryId,
            'iconImage': personalMarkerImageId(markers[index].categoryId),
            'sortKey': index,
          },
        ),
    ],
  });

  static String currentLocation({
    required LatLng? point,
    required double accuracyMeters,
    required bool hasAccuracy,
  }) => jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      if (point case final location? when _hasValidCoordinates(location))
        _pointFeature(
          id: 'current-location',
          point: location,
          properties: {
            'latitude': location.latitude,
            'accuracyMeters': accuracyMeters,
            'hasAccuracy': hasAccuracy,
            'iconImage': 'suelosar-current-location',
          },
        ),
    ],
  });

  static Map<String, Object?> _pointFeature({
    required String id,
    required LatLng point,
    required Map<String, Object?> properties,
  }) => {
    'type': 'Feature',
    'id': id,
    'properties': properties,
    'geometry': {
      'type': 'Point',
      'coordinates': [point.longitude, point.latitude],
    },
  };

  static bool _hasValidCoordinates(LatLng point) =>
      point.latitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude.isFinite &&
      point.longitude >= -180 &&
      point.longitude <= 180;
}
