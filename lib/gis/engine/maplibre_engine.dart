import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart' as app_geo;
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;
import 'package:path_provider/path_provider.dart';
import 'package:pmtiles/pmtiles.dart';

import '../../constants/asset_paths.dart';
import '../gis_feature.dart';
import '../gis_layer.dart';
import 'soil_map_engine.dart';

/// [SoilMapEngine] implementation backed by MapLibre Native, evaluated in
/// parallel with [FlutterMapEngine] (Etapa 3 — "implementación paralela").
///
/// **Not the active engine anywhere by default.** [GisMapScreen] only uses
/// this when a [SoilMapEngine] override is explicitly injected (see
/// `_useMapLibreEngineForDiagnostic` / the `engine` constructor parameter).
///
/// Integration approach validated in Etapa 1: MapLibre's Flutter plugin has
/// no built-in PMTiles reader, so this engine copies the real
/// `soil_polygons.pmtiles` asset to local storage (same asset SuelosAR
/// already ships), opens it with the `pmtiles` package (the same package
/// `PmTilesGisRepository` uses — `gis_repository.dart` itself is not
/// touched), and serves decoded MVT tiles over a loopback HTTP server that
/// MapLibre's vector source requests tiles from.
///
/// Scope, updated in the Etapa 3 continuation ("paridad funcional"): map,
/// camera, real PMTiles loading, soil-polygon rendering with the app's
/// actual theme colors, real attribute retrieval, tap-to-select with visual
/// highlight, personal markers, GPS visual, the offline reference basemap,
/// and basic (tap-to-append) distance/area measurement. NOT implemented:
/// interactive measurement editing (drag a vertex, insert mid-edge) — see
/// the architecture note on [SoilMapEngine.latLngToScreenOffset].
class MapLibreEngine implements SoilMapEngine {
  static const String _fillLayerId = 'soil-fill-uniform';
  static const String _selectedFillLayerId = 'soil-fill-selected';
  static const String _outlineLayerId = 'soil-outline';
  static const String _sourceId = 'soil';
  static const String _selectionMatchProperty = 'OBJECTID';

  static const String _refProvincialBoundariesId = 'ref-provincial-boundaries';
  static const String _refDepartmentBoundariesId = 'ref-department-boundaries';
  static const String _refRiversId = 'ref-rivers';
  static const String _refNationalRoadsId = 'ref-national-roads';
  static const String _refProvincialRoadsId = 'ref-provincial-roads';
  static const String _refCityCirclesId = 'ref-city-circles';
  static const String _refCityLabelsId = 'ref-city-labels';
  static const String _refSourceId = 'reference-basemap';
  static const List<String> _referenceLayerIds = [
    _refProvincialBoundariesId,
    _refDepartmentBoundariesId,
    _refRiversId,
    _refNationalRoadsId,
    _refProvincialRoadsId,
    _refCityCirclesId,
    _refCityLabelsId,
  ];

  maplibre.MapLibreMapController? _controller;
  HttpServer? _server;
  PmTilesArchive? _archive;
  String? _layerName;
  int? _minZoom;
  int? _maxZoom;
  String? _selectedFeatureId;
  bool _soilPolygonsVisible = true;
  bool _referenceBasemapVisible = true;
  String _normalFillColorHex = '#2E7D32';
  String _selectedFillColorHex = '#00695C';
  Map<String, Object?>? _referenceGeoJson;

  ValueChanged<String>? _onMarkerTap;
  final List<maplibre.Circle> _markerCircles = <maplibre.Circle>[];
  maplibre.Circle? _locationCircle;
  maplibre.Fill? _accuracyFill;
  maplibre.Line? _measurementLine;
  maplibre.Fill? _measurementFill;
  final List<maplibre.Symbol> _measurementVertexSymbols = <maplibre.Symbol>[];
  final Set<String> _registeredBadgeImages = <String>{};
  List<app_geo.LatLng> _lastDistancePoints = const [];
  List<app_geo.LatLng> _lastAreaPoints = const [];
  Color? _lastMeasurementColor;
  void Function(int index, Offset screenPosition)? _onVertexTap;
  void Function(int index)? _onVertexDragStart;
  void Function(int index, app_geo.LatLng newPoint)? _onVertexDragUpdate;
  void Function(int index)? _onVertexDragEnd;
  // Non-null while a vertex is actively being dragged — lets
  // setMeasurementGeometry take a cheap "move the line/fill only" path
  // instead of a full remove+re-add of every annotation on every drag
  // frame (see the ANR fix earlier in Etapa 3 for why that matters here).
  int? _draggingVertexIndex;

  // `buildMapSurface` is called on every GisMapScreen rebuild (any setState
  // anywhere in the screen), which used to call `_buildStyle()` — a
  // ~270KB jsonEncode including the reference basemap — fresh every time.
  // During rapid rebuild bursts (e.g. the tools FAB's expand animation) that
  // was enough to stall the UI isolate long enough to trigger an ANR on the
  // emulator. Cached here and only rebuilt when a style-affecting input
  // actually changes (see the explicit `_styleCache = null` invalidations
  // below), not on every widget rebuild.
  String? _styleCache;

  SoilMapCameraState _lastCamera = const SoilMapCameraState(
    center: app_geo.LatLng(0, 0),
    zoom: 0,
    rotation: 0,
  );

  @override
  Widget buildMapSurface({
    Key? key,
    required app_geo.LatLng initialCenter,
    required double initialZoom,
    required double minZoom,
    required double maxZoom,
    required Color backgroundColor,
    required bool gesturesEnabled,
    required SoilMapReadyCallback onReady,
    required SoilMapPositionChangedCallback onPositionChanged,
    SoilMapTapCallback? onTap,
    required List<Widget> children,
  }) {
    _lastCamera = SoilMapCameraState(
      center: initialCenter,
      zoom: initialZoom,
      rotation: 0,
    );
    return maplibre.MapLibreMap(
      key: key,
      styleString: _buildStyle(),
      initialCameraPosition: maplibre.CameraPosition(
        target: _toMaplibreLatLng(initialCenter),
        zoom: initialZoom,
      ),
      minMaxZoomPreference: maplibre.MinMaxZoomPreference(minZoom, maxZoom),
      scrollGesturesEnabled: gesturesEnabled,
      zoomGesturesEnabled: gesturesEnabled,
      rotateGesturesEnabled: gesturesEnabled,
      tiltGesturesEnabled: gesturesEnabled,
      dragEnabled: gesturesEnabled,
      // Fill and Line annotations (the measurement area's translucent
      // polygon and its boundary line) are deliberately excluded here. The
      // plugin resolves a tap to exactly one annotation type, and both the
      // fill (covering the polygon's whole interior, including every vertex
      // sitting on its own boundary) and the line (the measurement boundary
      // itself, which mid-segment point insertion needs `onMapClick` — not
      // an annotation tap — to reach) have no useful `data` attached and
      // aren't meant to be independently tappable/draggable. Leaving them in
      // this list silently swallowed taps/drags meant for the vertex Symbol
      // underneath, or for `onMapClick`'s edge-insertion logic. Excluding
      // them lets those touches reach the Symbol/Circle layers, or fall
      // through to `onMapClick`, instead — which is all this engine needs.
      annotationConsumeTapEvents: const [
        maplibre.AnnotationType.symbol,
        maplibre.AnnotationType.circle,
      ],
      onMapCreated: (controller) {
        _controller = controller;
        controller.onFeatureTapped.add(_handleFeatureTapped);
        controller.onFeatureDrag.add(_handleFeatureDrag);
        unawaited(controller.setSymbolIconAllowOverlap(true));
      },
      onStyleLoadedCallback: onReady,
      onCameraMove: (position) {
        _lastCamera = _toState(position);
        // MapLibre's onCameraMove does not distinguish gesture vs
        // programmatic moves the way flutter_map's onPositionChanged does.
        // Treated as `hasGesture: true`; the only current consumer clears
        // GPS "follow me" mode — harmless if cleared a little more eagerly.
        onPositionChanged(_lastCamera, hasGesture: true);
      },
      onMapClick: onTap == null
          ? null
          : (point, coordinates) {
              onTap(
                SoilMapTapDetails(
                  screenOffset: Offset(point.x.toDouble(), point.y.toDouble()),
                  point: _toLatLng2(coordinates),
                ),
              );
            },
    );
  }

  /// `Annotation` doesn't declare `.data` itself (only its concrete
  /// subtypes — `Circle`, `Symbol`, ...) — this narrows to the ones this
  /// engine actually attaches `data` to.
  Map<String, dynamic>? _dataOf(maplibre.Annotation? annotation) {
    return switch (annotation) {
      maplibre.Circle circle => circle.data,
      maplibre.Symbol symbol => symbol.data,
      _ => null,
    };
  }

  void _handleFeatureTapped(
    math.Point<double> point,
    maplibre.LatLng coordinates,
    String id,
    String layerId,
    maplibre.Annotation? annotation,
  ) {
    final data = _dataOf(annotation);
    if (data == null) return;
    switch (data['type']) {
      case 'marker':
        final markerId = data['markerId'] as String?;
        if (markerId != null) _onMarkerTap?.call(markerId);
      case 'vertex':
        final index = data['index'] as int?;
        if (index != null) {
          _onVertexTap?.call(
            index,
            Offset(point.x.toDouble(), point.y.toDouble()),
          );
        }
    }
  }

  void _handleFeatureDrag(
    math.Point<double> point,
    maplibre.LatLng origin,
    maplibre.LatLng current,
    maplibre.LatLng delta,
    String id,
    maplibre.Annotation? annotation,
    maplibre.DragEventType eventType,
  ) {
    final data = _dataOf(annotation);
    if (data == null || data['type'] != 'vertex') return;
    final index = data['index'] as int?;
    if (index == null) return;
    switch (eventType) {
      case maplibre.DragEventType.start:
        _draggingVertexIndex = index;
        _onVertexDragStart?.call(index);
      case maplibre.DragEventType.drag:
        _onVertexDragUpdate?.call(index, _toLatLng2(current));
      case maplibre.DragEventType.end:
        _draggingVertexIndex = null;
        _onVertexDragEnd?.call(index);
    }
  }

  @override
  SoilMapCameraState get camera => _lastCamera;

  @override
  void move(app_geo.LatLng center, double zoom) {
    unawaited(
      _controller?.moveCamera(
        maplibre.CameraUpdate.newLatLngZoom(_toMaplibreLatLng(center), zoom),
      ),
    );
  }

  @override
  void rotate(double degrees) {
    unawaited(_controller?.moveCamera(maplibre.CameraUpdate.bearingTo(degrees)));
  }

  @override
  SoilMapCameraState fitBounds(
    List<app_geo.LatLng> points, {
    EdgeInsets padding = EdgeInsets.zero,
    double? maxZoom,
  }) {
    if (points.isEmpty) return _lastCamera;
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final point in points.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    final center = app_geo.LatLng((south + north) / 2, (west + east) / 2);
    // Longitude degrees are narrower than latitude degrees away from the
    // equator — scale the east/west span by cos(latitude) before comparing
    // it against the north/south span, otherwise wide-but-flat bounds near
    // ±35° (Buenos Aires) end up under-zoomed. Still an estimate (no access
    // to the real viewport pixel size here, unlike flutter_map's
    // CameraFit), but a materially better one than a raw degree comparison.
    final latRadians = center.latitude * math.pi / 180;
    final lngSpanCorrected = (east - west).abs() * math.cos(latRadians).abs();
    final latSpan = (north - south).abs();
    final span = math.max(latSpan, lngSpanCorrected);
    final estimatedZoom = span <= 0
        ? (maxZoom ?? _lastCamera.zoom)
        : (math.log(360 / span) / math.ln2).clamp(2.0, maxZoom ?? 18.0);
    return SoilMapCameraState(center: center, zoom: estimatedZoom, rotation: 0);
  }

  @override
  Offset? latLngToScreenOffset(app_geo.LatLng point) {
    // MapLibre only exposes this projection asynchronously
    // (`controller.toScreenLocation`), unlike flutter_map's synchronous
    // MapCamera API that this interface method was originally shaped
    // around. Interactive measurement editing (drag/insert-mid-edge) is the
    // only caller and is deliberately out of scope — see the Etapa 3
    // continuation report's architecture note.
    return null;
  }

  @override
  app_geo.LatLng? screenOffsetToLatLng(Offset offset) {
    // See latLngToScreenOffset — same reasoning.
    return null;
  }

  @override
  Future<void> loadSoilPolygonsLayer({
    required GisArchiveInfo archiveInfo,
    required String layerName,
    required Color normalFillColor,
    required Color selectedFillColor,
  }) async {
    await _server?.close(force: true);
    await _archive?.close();

    _layerName = layerName;
    _minZoom = archiveInfo.minZoom;
    _maxZoom = archiveInfo.maxZoom;
    _normalFillColorHex = _toHexColor(normalFillColor);
    _selectedFillColorHex = _toHexColor(selectedFillColor);

    final archiveFile = await _prepareArchiveFile();
    final archive = await PmTilesArchive.fromFile(archiveFile);
    if (archive.tileType != TileType.mvt) {
      await archive.close();
      throw StateError('El archivo PMTiles no contiene tiles MVT.');
    }
    _archive = archive;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handleTileRequest);
    _server = server;

    _styleCache = null;
    await _pushStyle();
  }

  @override
  void setSelectedSoilFeature(String? featureId) {
    _selectedFeatureId = featureId;
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.setFilter(_selectedFillLayerId, _selectionFilter()),
    );
    unawaited(
      controller.setLayerVisibility(
        _selectedFillLayerId,
        _soilPolygonsVisible && featureId != null,
      ),
    );
  }

  List<Object?> _selectionFilter() {
    return <Object?>[
      '==',
      <Object?>['get', _selectionMatchProperty],
      _selectedFeatureId ?? '',
    ];
  }

  @override
  Future<GisFeature?> hitTestSoilFeature(Offset screenOffset) async {
    final controller = _controller;
    if (controller == null || !_soilPolygonsVisible) {
      return null;
    }
    List<dynamic> features;
    try {
      features = await controller.queryRenderedFeatures(
        math.Point<double>(screenOffset.dx, screenOffset.dy),
        [_fillLayerId],
        null,
      );
    } catch (_) {
      return null;
    }
    if (features.isEmpty) {
      return null;
    }
    final raw = features.first;
    if (raw is! Map) {
      return null;
    }
    final rawProperties = raw['properties'];
    final properties = <String, Object?>{
      if (rawProperties is Map)
        for (final entry in rawProperties.entries)
          entry.key.toString(): entry.value,
    };
    return _toGisFeature(properties);
  }

  @override
  void setSoilPolygonsVisible(bool visible) {
    _soilPolygonsVisible = visible;
    final controller = _controller;
    if (controller == null) return;
    unawaited(controller.setLayerVisibility(_fillLayerId, visible));
    unawaited(controller.setLayerVisibility(_outlineLayerId, visible));
    unawaited(
      controller.setLayerVisibility(
        _selectedFillLayerId,
        visible && _selectedFeatureId != null,
      ),
    );
  }

  @override
  void setReferenceBasemapVisible(bool visible) {
    _referenceBasemapVisible = visible;
    final controller = _controller;
    if (controller == null || _referenceGeoJson == null) return;
    for (final layerId in _referenceLayerIds) {
      unawaited(controller.setLayerVisibility(layerId, visible));
    }
  }

  @override
  Future<void> loadReferenceBasemap() async {
    if (_referenceGeoJson != null) return;
    final rawJson = await rootBundle.loadString(
      AssetPaths.agronomicReferenceMap,
    );
    final json = jsonDecode(rawJson) as Map<String, dynamic>;
    final layers = Map<String, dynamic>.from(json['layers'] as Map);
    _referenceGeoJson = _buildReferenceGeoJson(layers);
    _styleCache = null;
    await _pushStyle();
  }

  Map<String, Object?> _buildReferenceGeoJson(Map<String, dynamic> layers) {
    List<Object?> lineFeatures(String key) {
      final lines = (layers[key] as List<dynamic>? ?? const []);
      return [
        for (final line in lines)
          {
            'type': 'Feature',
            'properties': const <String, Object?>{},
            'geometry': {'type': 'LineString', 'coordinates': line},
          },
      ];
    }

    final cities = (layers['majorCities'] as List<dynamic>? ?? const []);
    final cityFeatures = [
      for (final city in cities)
        {
          'type': 'Feature',
          'properties': {
            'name': city['name'],
            'isPrimary': city['importance'] == 'primary',
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [city['lon'], city['lat']],
          },
        },
    ];

    return {
      'type': 'FeatureCollection',
      'features': [
        ...lineFeatures('provincialBoundaries'),
        ...lineFeatures('departmentBoundaries'),
        ...lineFeatures('majorRivers'),
        ...lineFeatures('nationalRoads'),
        ...lineFeatures('provincialRoads'),
        ...cityFeatures,
      ],
    };
  }

  @override
  void setPersonalMarkers(
    List<SoilMapMarkerPin> markers, {
    required ValueChanged<String> onMarkerTap,
  }) {
    _onMarkerTap = onMarkerTap;
    final controller = _controller;
    if (controller == null) return;
    unawaited(_replaceMarkerCircles(controller, markers));
  }

  Future<void> _replaceMarkerCircles(
    maplibre.MapLibreMapController controller,
    List<SoilMapMarkerPin> markers,
  ) async {
    if (_markerCircles.isNotEmpty) {
      await controller.removeCircles(_markerCircles);
      _markerCircles.clear();
    }
    if (markers.isEmpty) return;
    final added = await controller.addCircles(
      [
        for (final marker in markers)
          maplibre.CircleOptions(
            geometry: _toMaplibreLatLng(marker.point),
            circleRadius: 9,
            circleColor: '#D11313',
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2,
          ),
      ],
      [for (final marker in markers) {'type': 'marker', 'markerId': marker.id}],
    );
    _markerCircles.addAll(added);
  }

  @override
  void setCurrentLocationMarker({
    app_geo.LatLng? point,
    double? accuracyMeters,
    required bool showAccuracyCircle,
  }) {
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      _updateLocationMarker(controller, point, accuracyMeters, showAccuracyCircle),
    );
  }

  Future<void> _updateLocationMarker(
    maplibre.MapLibreMapController controller,
    app_geo.LatLng? point,
    double? accuracyMeters,
    bool showAccuracyCircle,
  ) async {
    if (point == null) {
      if (_locationCircle != null) {
        await controller.removeCircle(_locationCircle!);
        _locationCircle = null;
      }
      if (_accuracyFill != null) {
        await controller.removeFill(_accuracyFill!);
        _accuracyFill = null;
      }
      return;
    }

    if (_locationCircle == null) {
      _locationCircle = await controller.addCircle(
        maplibre.CircleOptions(
          geometry: _toMaplibreLatLng(point),
          circleRadius: 7,
          circleColor: '#1976D2',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
      );
    } else {
      await controller.updateCircle(
        _locationCircle!,
        maplibre.CircleOptions(geometry: _toMaplibreLatLng(point)),
      );
    }

    final hasAccuracy =
        showAccuracyCircle && accuracyMeters != null && accuracyMeters.isFinite && accuracyMeters > 0;
    if (!hasAccuracy) {
      if (_accuracyFill != null) {
        await controller.removeFill(_accuracyFill!);
        _accuracyFill = null;
      }
      return;
    }
    final ring = _geodesicCircle(point, accuracyMeters);
    if (_accuracyFill == null) {
      _accuracyFill = await controller.addFill(
        maplibre.FillOptions(
          geometry: [ring],
          fillColor: '#1976D2',
          fillOpacity: 0.15,
        ),
      );
    } else {
      await controller.updateFill(
        _accuracyFill!,
        maplibre.FillOptions(geometry: [ring]),
      );
    }
  }

  /// Generates a 32-point geodesic circle polygon around [center] with
  /// [radiusMeters], so the accuracy fill is drawn in real-world meters
  /// (matching flutter_map's `useRadiusInMeter: true`) instead of a
  /// fixed pixel radius that would grow/shrink oddly with zoom.
  List<maplibre.LatLng> _geodesicCircle(
    app_geo.LatLng center,
    double radiusMeters,
  ) {
    const earthRadius = 6371000.0;
    final angularDistance = radiusMeters / earthRadius;
    final centerLatRad = center.latitude * math.pi / 180;
    final centerLngRad = center.longitude * math.pi / 180;
    return [
      for (var i = 0; i <= 32; i++)
        () {
          final bearing = 2 * math.pi * i / 32;
          final lat2 = math.asin(
            math.sin(centerLatRad) * math.cos(angularDistance) +
                math.cos(centerLatRad) * math.sin(angularDistance) * math.cos(bearing),
          );
          final lng2 = centerLngRad +
              math.atan2(
                math.sin(bearing) * math.sin(angularDistance) * math.cos(centerLatRad),
                math.cos(angularDistance) - math.sin(centerLatRad) * math.sin(lat2),
              );
          return maplibre.LatLng(lat2 * 180 / math.pi, lng2 * 180 / math.pi);
        }(),
    ];
  }

  @override
  void setMeasurementGeometry({
    required List<app_geo.LatLng> distancePoints,
    required List<app_geo.LatLng> areaPoints,
    required Color color,
    required void Function(int index, Offset screenPosition) onVertexTap,
    required void Function(int index) onVertexDragStart,
    required void Function(int index, app_geo.LatLng newPoint)
    onVertexDragUpdate,
    required void Function(int index) onVertexDragEnd,
  }) {
    _onVertexTap = onVertexTap;
    _onVertexDragStart = onVertexDragStart;
    _onVertexDragUpdate = onVertexDragUpdate;
    _onVertexDragEnd = onVertexDragEnd;

    final colorUnchanged = color == _lastMeasurementColor;
    if (_listEquals(distancePoints, _lastDistancePoints) &&
        _listEquals(areaPoints, _lastAreaPoints) &&
        colorUnchanged) {
      return;
    }

    final controller = _controller;
    final structurallyUnchanged =
        distancePoints.length == _lastDistancePoints.length &&
        areaPoints.length == _lastAreaPoints.length;
    if (_draggingVertexIndex != null &&
        structurallyUnchanged &&
        colorUnchanged &&
        controller != null) {
      // Active drag: only the dragged point's coordinates changed. Move the
      // line/fill outline to follow it — the dragged vertex's own icon is
      // already being repositioned natively by MapLibre's draggable
      // annotation, and the other vertices didn't move, so re-adding every
      // symbol/line/fill on each drag frame (like the full path below does)
      // would be wasteful and risks the jank/ANR the earlier style-cache fix
      // addressed.
      _lastDistancePoints = List.of(distancePoints);
      _lastAreaPoints = List.of(areaPoints);
      unawaited(
        _updateMeasurementShapeOnly(controller, distancePoints, areaPoints),
      );
      return;
    }

    _lastDistancePoints = List.of(distancePoints);
    _lastAreaPoints = List.of(areaPoints);
    _lastMeasurementColor = color;
    if (controller == null) return;
    unawaited(
      _redrawMeasurement(controller, distancePoints, areaPoints, color),
    );
  }

  Future<void> _updateMeasurementShapeOnly(
    maplibre.MapLibreMapController controller,
    List<app_geo.LatLng> distancePoints,
    List<app_geo.LatLng> areaPoints,
  ) async {
    final maplibreArea = areaPoints.map(_toMaplibreLatLng).toList();
    final points = areaPoints.isNotEmpty ? areaPoints : distancePoints;
    final maplibrePoints = points.map(_toMaplibreLatLng).toList();
    final fill = _measurementFill;
    if (fill != null && maplibreArea.length >= 3) {
      await controller.updateFill(
        fill,
        maplibre.FillOptions(geometry: [[...maplibreArea, maplibreArea.first]]),
      );
    }
    final line = _measurementLine;
    if (line != null && maplibrePoints.length >= 2) {
      final lineGeometry = maplibreArea.length >= 3
          ? [...maplibreArea, maplibreArea.first]
          : maplibrePoints;
      await controller.updateLine(
        line,
        maplibre.LineOptions(geometry: lineGeometry),
      );
    }
  }

  bool _listEquals(List<app_geo.LatLng> a, List<app_geo.LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }

  Future<void> _redrawMeasurement(
    maplibre.MapLibreMapController controller,
    List<app_geo.LatLng> distancePoints,
    List<app_geo.LatLng> areaPoints,
    Color color,
  ) async {
    if (_measurementVertexSymbols.isNotEmpty) {
      await controller.removeSymbols(_measurementVertexSymbols);
      _measurementVertexSymbols.clear();
    }
    if (_measurementLine != null) {
      await controller.removeLine(_measurementLine!);
      _measurementLine = null;
    }
    if (_measurementFill != null) {
      await controller.removeFill(_measurementFill!);
      _measurementFill = null;
    }

    final hex = _toHexColor(color);
    final points = areaPoints.isNotEmpty ? areaPoints : distancePoints;
    if (points.isEmpty) return;
    final maplibreArea = areaPoints.map(_toMaplibreLatLng).toList();
    final maplibrePoints = points.map(_toMaplibreLatLng).toList();

    if (maplibreArea.length >= 3) {
      _measurementFill = await controller.addFill(
        maplibre.FillOptions(
          geometry: [[...maplibreArea, maplibreArea.first]],
          fillColor: hex,
          fillOpacity: 0.25,
        ),
      );
    }
    if (maplibrePoints.length >= 2) {
      final lineGeometry = maplibreArea.length >= 3
          ? [...maplibreArea, maplibreArea.first]
          : maplibrePoints;
      _measurementLine = await controller.addLine(
        maplibre.LineOptions(
          geometry: lineGeometry,
          lineColor: hex,
          lineWidth: 3,
        ),
      );
    }
    // Numbered vertex badges — matches _MeasurementLayer._buildEditableVertexMarker
    // (labels '1', '2', ... in the app's selected measurement color), but
    // rendered as a bitmap via Canvas/TextPainter and shown through
    // addImage + a Symbol layer: MapLibre's own glyph system needs a
    // `glyphs` PBF source we don't bundle (kept fully offline — see the
    // Etapa 3 report), while Flutter's own text rendering needs nothing
    // extra and produces the same visual result for a fixed short label.
    for (var i = 0; i < maplibrePoints.length; i++) {
      final imageName = _vertexBadgeImageName(i + 1, hex);
      if (_registeredBadgeImages.add(imageName)) {
        final bytes = await _renderVertexBadge('${i + 1}', color);
        await controller.addImage(imageName, bytes);
      }
    }
    _measurementVertexSymbols.addAll(
      await controller.addSymbols(
        [
          for (var i = 0; i < maplibrePoints.length; i++)
            maplibre.SymbolOptions(
              geometry: maplibrePoints[i],
              iconImage: _vertexBadgeImageName(i + 1, hex),
              iconSize: i == 0 ? 0.55 : 0.45,
              draggable: true,
            ),
        ],
        [for (var i = 0; i < maplibrePoints.length; i++) {'type': 'vertex', 'index': i}],
      ),
    );
  }

  String _vertexBadgeImageName(int number, String colorHex) =>
      'vertex-badge-$number-$colorHex';

  /// Renders a small numbered circular badge to a PNG, purely with
  /// Flutter's own Canvas/TextPainter — no MapLibre glyph/font resource
  /// needed, so this stays fully offline.
  Future<Uint8List> _renderVertexBadge(String label, Color color) async {
    const double diameter = 72;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final backgroundPaint = ui.Paint()..color = color;
    canvas.drawCircle(
      const Offset(diameter / 2, diameter / 2),
      diameter / 2 - 2,
      backgroundPaint,
    );
    final borderPaint = ui.Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(
      const Offset(diameter / 2, diameter / 2),
      diameter / 2 - 2,
      borderPaint,
    );
    // White text with a dark halo reads on any measurement color (blue,
    // orange or red), avoiding the need to know which text color pairs
    // with which background (that pairing — MeasurementColorOption.onColor
    // — lives in a model this engine intentionally doesn't depend on).
    final haloPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = const Color(0x99000000),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          color: Color(0xFFFFFFFF),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final textOffset = Offset(
      (diameter - textPainter.width) / 2,
      (diameter - textPainter.height) / 2,
    );
    haloPainter.paint(canvas, textOffset);
    textPainter.paint(canvas, textOffset);
    final picture = recorder.endRecording();
    final image = await picture.toImage(diameter.toInt(), diameter.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  @override
  void dispose() {
    unawaited(_server?.close(force: true));
    unawaited(_archive?.close());
  }

  Future<File> _prepareArchiveFile() async {
    final byteData = await rootBundle.load(AssetPaths.gisPmTiles);
    final version = (await rootBundle.loadString(
      AssetPaths.gisPmTilesVersion,
    )).trim();
    final directory = await getApplicationSupportDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}soil_polygons_maplibre_$version.pmtiles',
    );
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    if (!await file.exists() || await file.length() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file;
  }

  Future<void> _handleTileRequest(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length != 4 || segments[0] != 'tiles') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final archive = _archive;
    if (archive == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    try {
      final z = int.parse(segments[1]);
      final x = int.parse(segments[2]);
      final y = int.parse(segments[3].split('.').first);
      final tileId = ZXY(z, x, y).toTileId();
      final tile = await archive.tile(tileId);
      request.response.headers.set('Content-Type', 'application/x-protobuf');
      request.response.add(tile.bytes());
      await request.response.close();
    } on TileNotFoundException {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  /// Pushes a freshly built style to the live controller, if the map has
  /// already been created. Used after loading the PMTiles bridge and after
  /// loading the reference basemap GeoJSON.
  Future<void> _pushStyle() async {
    final controller = _controller;
    if (controller != null) {
      await controller.setStyle(_buildStyle());
    }
  }

  String _buildStyle() {
    final cached = _styleCache;
    if (cached != null) return cached;

    final server = _server;
    final layerName = _layerName;

    final sources = <String, Object?>{};
    final layers = <Object?>[
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': '#FAFAF8'},
      },
    ];

    final referenceGeoJson = _referenceGeoJson;
    if (referenceGeoJson != null) {
      sources[_refSourceId] = {'type': 'geojson', 'data': referenceGeoJson};
      final refVisibility = _referenceBasemapVisible ? 'visible' : 'none';
      layers.addAll([
        {
          'id': _refProvincialBoundariesId,
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', '\$type', 'LineString'],
          'layout': {'visibility': refVisibility},
          'paint': {'line-color': '#AEB4AC', 'line-width': 0.9},
        },
        {
          'id': _refDepartmentBoundariesId,
          'type': 'line',
          'source': _refSourceId,
          'minzoom': 7.8,
          'filter': ['==', '\$type', 'LineString'],
          'layout': {'visibility': refVisibility},
          'paint': {'line-color': '#CFD3CC', 'line-width': 0.5},
        },
        {
          'id': _refRiversId,
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', '\$type', 'LineString'],
          'layout': {'visibility': refVisibility},
          'paint': {'line-color': '#6BA9CC', 'line-width': 1.4},
        },
        {
          'id': _refNationalRoadsId,
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', '\$type', 'LineString'],
          'layout': {'visibility': refVisibility},
          'paint': {'line-color': '#BD5738', 'line-width': 1.4},
        },
        {
          'id': _refProvincialRoadsId,
          'type': 'line',
          'source': _refSourceId,
          'minzoom': 8.2,
          'filter': ['==', '\$type', 'LineString'],
          'layout': {'visibility': refVisibility},
          'paint': {'line-color': '#D77A59', 'line-width': 1.0},
        },
        {
          'id': _refCityCirclesId,
          'type': 'circle',
          'source': _refSourceId,
          'filter': ['==', '\$type', 'Point'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'circle-color': '#303632',
            'circle-radius': [
              'case', ['get', 'isPrimary'], 2.7, 2.3,
            ],
          },
        },
        {
          'id': _refCityLabelsId,
          'type': 'symbol',
          'source': _refSourceId,
          'filter': ['==', '\$type', 'Point'],
          'layout': {
            'visibility': refVisibility,
            'text-field': ['get', 'name'],
            'text-size': ['case', ['get', 'isPrimary'], 15.0, 13.0],
            'text-anchor': 'left',
            'text-offset': [0.6, 0],
            'text-font': ['Open Sans Regular'],
          },
          'paint': {
            'text-color': '#29312C',
            'text-halo-color': '#FCFCFA',
            'text-halo-width': 1.2,
          },
        },
      ]);
    }

    if (server != null && layerName != null) {
      final tileUrl = 'http://127.0.0.1:${server.port}/tiles/{z}/{x}/{y}.pbf';
      sources[_sourceId] = {
        'type': 'vector',
        'tiles': [tileUrl],
        'minzoom': _minZoom ?? 4,
        'maxzoom': _maxZoom ?? 14,
      };
      // Reproduces GisMapScreen's current soil-polygon style
      // (_GisPolygonStyle.fromColorScheme): a flat, low-opacity fill in the
      // app's actual primary/tertiary theme colors, passed in by
      // loadSoilPolygonsLayer — not hardcoded.
      layers.addAll([
        {
          'id': _fillLayerId,
          'type': 'fill',
          'source': _sourceId,
          'source-layer': layerName,
          'layout': {
            'visibility': _soilPolygonsVisible ? 'visible' : 'none',
          },
          'paint': {'fill-color': _normalFillColorHex, 'fill-opacity': 0.10},
        },
        {
          'id': _selectedFillLayerId,
          'type': 'fill',
          'source': _sourceId,
          'source-layer': layerName,
          'filter': _selectionFilter(),
          'layout': {
            'visibility':
                _soilPolygonsVisible && _selectedFeatureId != null
                    ? 'visible'
                    : 'none',
          },
          'paint': {
            'fill-color': _selectedFillColorHex,
            'fill-opacity': 0.55,
          },
        },
        {
          'id': _outlineLayerId,
          'type': 'line',
          'source': _sourceId,
          'source-layer': layerName,
          'layout': {
            'visibility': _soilPolygonsVisible ? 'visible' : 'none',
          },
          'paint': {'line-color': _normalFillColorHex, 'line-width': 1.0},
        },
      ]);
    }

    final built = jsonEncode({'version': 8, 'sources': sources, 'layers': layers});
    _styleCache = built;
    return built;
  }

  GisFeature _toGisFeature(Map<String, Object?> properties) {
    final id =
        properties['OBJECTID']?.toString() ??
        properties['OBJECTID_1']?.toString() ??
        properties.hashCode.toString();
    return GisFeature(
      id: id,
      // Full ring geometry is not needed by the selection/attribute panel
      // this milestone exercises (it reads .properties/.locality/
      // .soilMapId, not .geometry) — see the design note in the Etapa 3
      // report. Left empty rather than reconstructed from MapLibre's tile
      // geometry to avoid duplicating gis_repository.dart's projection
      // logic outside of it.
      geometry: const GisGeometry(type: 'Polygon', coordinates: <Object?>[]),
      properties: properties,
      locality:
          (properties['locality'] ?? properties['localidad'] ?? '').toString(),
      soilMapId: _readInt(properties['soilMapId'] ?? properties['soil_map_id']),
    );
  }

  int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _toHexColor(Color color) {
    String channel(double component) =>
        (component * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${channel(color.r)}${channel(color.g)}${channel(color.b)}';
  }

  SoilMapCameraState _toState(maplibre.CameraPosition position) {
    return SoilMapCameraState(
      center: _toLatLng2(position.target),
      zoom: position.zoom,
      rotation: position.bearing,
    );
  }

  maplibre.LatLng _toMaplibreLatLng(app_geo.LatLng point) {
    return maplibre.LatLng(point.latitude, point.longitude);
  }

  app_geo.LatLng _toLatLng2(maplibre.LatLng point) {
    return app_geo.LatLng(point.latitude, point.longitude);
  }
}
