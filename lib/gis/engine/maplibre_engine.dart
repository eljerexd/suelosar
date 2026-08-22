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
  static const String _selectedOutlineLayerId = 'soil-outline-selected';
  static const String _sourceId = 'soil';
  static const String _selectionMatchProperty = 'OBJECTID';

  static const String _refProvincialBoundariesId = 'ref-provincial-boundaries';
  static const String _refDepartmentBoundariesId = 'ref-department-boundaries';
  static const String _refRiversId = 'ref-rivers';
  static const String _refNationalRoadsId = 'ref-national-roads';
  static const String _refProvincialRoadsId = 'ref-provincial-roads';
  static const String _refCityCirclesId = 'ref-city-circles';
  static const String _refCityLabelsId = 'ref-city-labels';
  static const String _refCityLabelsSecondaryId = 'ref-city-labels-secondary';
  static const String _refSourceId = 'reference-basemap';
  static const List<String> _referenceLayerIds = [
    _refProvincialBoundariesId,
    _refDepartmentBoundariesId,
    '$_refRiversId-casing',
    _refRiversId,
    '$_refNationalRoadsId-casing',
    _refNationalRoadsId,
    '$_refProvincialRoadsId-casing',
    _refProvincialRoadsId,
    _refCityCirclesId,
    _refCityLabelsId,
    _refCityLabelsSecondaryId,
  ];

  // Measurement geometry (vertex badges + boundary line/fill) lives in a
  // single GeoJSON source, updated with one `setGeoJsonSource` call per
  // change — not three separate AnnotationManager-backed sources (Symbol +
  // Fill + Line), which is what let the renderer paint a frame reflecting
  // only some of the three during a drag. See the Etapa 3 report's root
  // cause investigation.
  static const String _measurementSourceId = 'measurement';
  static const String _measurementFillLayerId = 'measurement-fill';
  static const String _measurementLineLayerId = 'measurement-line';
  static const String _measurementSymbolLayerId = 'measurement-vertices';

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
  List<({String name, bool isPrimary})> _referenceCities = const [];
  final Set<String> _registeredCityLabelImages = <String>{};
  bool _cityLabelsLayerAdded = false;
  bool _cityLabelsSecondaryLayerAdded = false;

  ValueChanged<String>? _onMarkerTap;
  final List<maplibre.Symbol> _markerSymbols = <maplibre.Symbol>[];
  final Set<String> _registeredMarkerBadgeImages = <String>{};
  maplibre.Circle? _locationCircle;
  maplibre.Fill? _accuracyFill;
  maplibre.Line? _accuracyBorder;
  // Measurement geometry (vertex badges + boundary line/fill): whether
  // _measurementSourceId/its 3 layers have been created yet (addGeoJsonSource
  // + addLayer×3 happen once; every update after that is one
  // setGeoJsonSource call replacing the whole FeatureCollection atomically —
  // see the root-cause investigation in the Etapa 3 report for why this
  // replaced the previous SymbolManager/FillManager/LineManager-based
  // approach). Not using AnnotationManager here means there is no `.data`
  // to read back off a tapped/dragged `Annotation` (`getAnnotationById`
  // only knows about AnnotationManager-owned features) — instead
  // [_vertexFeatureIdToIndex] maps this engine's own feature ids (assigned
  // when building the FeatureCollection) back to a vertex index.
  bool _measurementLayersReady = false;
  final Map<String, int> _vertexFeatureIdToIndex = <String, int>{};
  final Set<String> _registeredBadgeImages = <String>{};
  List<app_geo.LatLng> _lastDistancePoints = const [];
  List<app_geo.LatLng> _lastAreaPoints = const [];
  Color? _lastMeasurementColor;
  int? _lastDraggedVertexIndex;
  int _measurementApplyFailureStreak = 0;
  void Function(int index, Offset screenPosition)? _onVertexTap;
  void Function(int index)? _onVertexDragStart;
  void Function(int index, app_geo.LatLng newPoint)? _onVertexDragUpdate;
  void Function(int index)? _onVertexDragEnd;
  // At most one `setGeoJsonSource` call in flight at a time for the
  // measurement source. Without this, a burst of drag events (which can
  // arrive faster than a platform-channel round trip completes) would queue
  // up redundant native work whose results get immediately superseded; a
  // call that lands while one is already running just replaces the pending
  // points instead of starting a second one, so we always converge on the
  // latest position without an unbounded backlog. This is a backpressure
  // mechanism, not a timing workaround — it does not delay or debounce
  // anything, it only skips already-superseded work.
  bool _geometryUpdateInFlight = false;
  List<app_geo.LatLng>? _pendingDistancePoints;
  List<app_geo.LatLng>? _pendingAreaPoints;
  Color? _pendingColor;
  int? _pendingDraggedVertexIndex;
  bool _pendingHasDraggedVertexIndex = false;

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
        zoom: _toEngineZoom(initialZoom),
      ),
      minMaxZoomPreference: maplibre.MinMaxZoomPreference(
        _toEngineZoom(minZoom),
        _toEngineZoom(maxZoom),
      ),
      scrollGesturesEnabled: gesturesEnabled,
      zoomGesturesEnabled: gesturesEnabled,
      rotateGesturesEnabled: gesturesEnabled,
      tiltGesturesEnabled: gesturesEnabled,
      dragEnabled: gesturesEnabled,
      // Default is [line, symbol, circle, fill] (bottom to top — see the
      // plugin's own doc comment on MapLibreMap.annotationOrder). That
      // stacks the GPS dot (circle, from _locationCircle) above personal
      // markers (symbol, from setPersonalMarkers) — FlutterMapEngine draws
      // markers above the GPS layer instead (see GisMapScreen._buildMap's
      // `children` Stack order: _CurrentLocationLayer, then personal
      // markers). It also puts the accuracy circle's translucent fill above
      // its own center dot. Reordered so symbol (markers) is topmost and
      // fill sits right after its line border, below the dot — matching
      // FlutterMapEngine's stacking without touching anything else.
      annotationOrder: const [
        maplibre.AnnotationType.line,
        maplibre.AnnotationType.fill,
        maplibre.AnnotationType.circle,
        maplibre.AnnotationType.symbol,
      ],
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
      onStyleLoadedCallback: () {
        // Fires every time the style finishes (re)loading, not just the
        // first — the one point guaranteed to have `style.isFullyLoaded()`
        // actually true, which is what addImage requires. Retrying city
        // label registration here (idempotent — see
        // _ensureCityLabelImagesRegistered) catches it even if every
        // earlier attempt (from _pushStyle, itself called from
        // loadReferenceBasemap before this ever fires the first time) hit
        // that race and failed.
        final controller = _controller;
        if (controller != null) {
          unawaited(_ensureCityLabelImagesRegistered(controller));
        }
        onReady();
      },
      onCameraMove: (position) {
        _lastCamera = _toState(position);
        // MapLibre's onCameraMove doesn't carry a reason the way
        // flutter_map's onPositionChanged does (gesture vs
        // controller.move()/.rotate()). [_programmaticCameraUpdateDepth] is
        // this engine's own bookkeeping of that: >0 exactly while a
        // move()/rotate() call of ours is in flight, so any onCameraMove
        // seen then is our own programmatic update, not a real gesture. See
        // [_runProgrammaticCameraUpdate] for why a depth counter instead of
        // a bool — GisMapScreen's "resume following location" flow moves
        // the camera every fresh GPS fix, matching flutter_map's own
        // `hasGesture: false` for that same programmatic move.
        onPositionChanged(
          _lastCamera,
          hasGesture: _programmaticCameraUpdateDepth == 0,
        );
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
    // Vertices live in this engine's own raw GeoJSON source (see
    // _measurementSourceId), not an AnnotationManager, so there is no
    // `Annotation.data` to read for them — only [_vertexFeatureIdToIndex]
    // (built when the FeatureCollection is written) knows what a given
    // feature id means. Markers are unaffected: they still go through
    // CircleManager, so `_dataOf(annotation)` still resolves for those.
    final vertexIndex = _vertexFeatureIdToIndex[id];
    if (vertexIndex != null) {
      _onVertexTap?.call(vertexIndex, Offset(point.x.toDouble(), point.y.toDouble()));
      return;
    }
    final data = _dataOf(annotation);
    if (data == null) return;
    if (data['type'] == 'marker') {
      final markerId = data['markerId'] as String?;
      if (markerId != null) _onMarkerTap?.call(markerId);
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
    // See _handleFeatureTapped — same reasoning, only vertices are
    // draggable so there is nothing else to dispatch here.
    final index = _vertexFeatureIdToIndex[id];
    if (index == null) return;
    switch (eventType) {
      case maplibre.DragEventType.start:
        _onVertexDragStart?.call(index);
      case maplibre.DragEventType.drag:
        _onVertexDragUpdate?.call(index, _toLatLng2(current));
      case maplibre.DragEventType.end:
        _onVertexDragEnd?.call(index);
    }
  }

  @override
  SoilMapCameraState get camera => _lastCamera;

  // >0 exactly while a move()/rotate() call below is awaiting its
  // moveCamera — see the onCameraMove doc comment in buildMapSurface for
  // why this exists. A counter, not a bool: _animateNorthRotation calls
  // rotate() once per animation frame, so overlapping in-flight calls are
  // the normal case, not an edge case — a bool would let the first call's
  // completion clear the flag while a second one is still in flight.
  int _programmaticCameraUpdateDepth = 0;

  Future<void> _runProgrammaticCameraUpdate(
    Future<void>? Function() startUpdate,
  ) async {
    _programmaticCameraUpdateDepth++;
    try {
      await startUpdate();
    } finally {
      _programmaticCameraUpdateDepth--;
    }
  }

  @override
  void move(app_geo.LatLng center, double zoom) {
    unawaited(
      _runProgrammaticCameraUpdate(
        () => _controller?.moveCamera(
          maplibre.CameraUpdate.newLatLngZoom(
            _toMaplibreLatLng(center),
            _toEngineZoom(zoom),
          ),
        ),
      ),
    );
  }

  // MapLibre GL (like Mapbox GL) sizes vector tiles for a 512px-per-tile
  // camera-zoom convention, while flutter_map (and this app's own zoom
  // math — GisArchiveInfo.minZoom/maxZoom, _tileCoordinatesForViewport,
  // the "zoom 7" reference used throughout GisMapScreen) uses the classic
  // 256px-per-tile convention. The same numeric zoom therefore shows twice
  // as much screen detail (a visibly closer frame) in MapLibre than in
  // flutter_map unless corrected — MapLibre's camera zoom is always one
  // level "ahead" of the app's logical zoom for an equivalent framing.
  static const double _zoomConventionOffset = 1;

  double _toEngineZoom(double logicalZoom) =>
      logicalZoom - _zoomConventionOffset;

  double _toLogicalZoom(double engineZoom) =>
      engineZoom + _zoomConventionOffset;

  @override
  void rotate(double degrees) {
    // [degrees] arrives in flutter_map's `camera.rotation` convention (the
    // map *content*'s on-screen rotation, clockwise-positive — see
    // flutter_map's mobile_layer_transformer.dart, which applies it as
    // `Transform.rotate(angle: camera.rotationRad, ...)` directly to the
    // content). MapLibre's `bearing` is the opposite quantity — the
    // direction the *camera* faces — so content and bearing rotate in
    // opposite directions for the same value. Negating here (and in
    // [_toState]) keeps both engines' `camera.rotation` meaning identical,
    // which is what the north-reset animation and the compass control
    // (both engine-agnostic, in gis_map_screen.dart) rely on.
    unawaited(
      _runProgrammaticCameraUpdate(
        () => _controller?.moveCamera(
          maplibre.CameraUpdate.bearingTo(-degrees),
        ),
      ),
    );
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
    unawaited(
      controller.setFilter(_selectedOutlineLayerId, _selectionFilter()),
    );
    unawaited(
      controller.setLayerVisibility(
        _selectedOutlineLayerId,
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
    unawaited(
      controller.setLayerVisibility(
        _selectedOutlineLayerId,
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
    _referenceCities = _parseCities(layers['majorCities']);
    _referenceGeoJson = _buildReferenceGeoJson(layers);
    final controller = _controller;
    if (controller != null) {
      await _ensureCityLabelImagesRegistered(controller);
    }
    _styleCache = null;
    await _pushStyle();
  }

  List<({String name, bool isPrimary})> _parseCities(Object? rawCities) {
    final cities = rawCities as List<dynamic>? ?? const [];
    return [
      for (final city in cities)
        (
          name: city['name'] as String,
          isPrimary: city['importance'] == 'primary',
        ),
    ];
  }

  // Only city features carry `labelImage` (line features' `properties` is
  // empty — see _buildReferenceGeoJson), so this selects exactly the city
  // rows without depending on the `$type` meta-filter being supported
  // identically through this addLayer path as it is when a filter is
  // parsed directly out of a full style JSON document (used elsewhere in
  // this engine, e.g. _refCityCirclesId's raw-JSON `_pushStyle` path).
  static const List<Object?> _cityLabelsFilter = ['has', 'labelImage'];

  // Split into two filters/layers (primary vs. secondary) rather than one
  // layer with a combined `case`/`*` iconOpacity expression: labels stopped
  // rendering entirely under the combined expression (city *circles*, which
  // use the same expression through the raw style-JSON `_pushStyle` path
  // instead of this Dart `addLayer`/SymbolLayerProperties path, kept
  // working) — filter + a plain per-layer interpolate is the same
  // mechanism already proven to work for every other reference-basemap
  // layer in this file (minzoom-gated department boundaries/provincial
  // roads), so it's the lower-risk way to keep "primary cities always
  // visible, secondary cities fade in 7.7→9.4".
  static const List<Object?> _cityLabelsPrimaryFilter = [
    'all',
    _cityLabelsFilter,
    ['==', ['get', 'isPrimary'], true],
  ];
  static const List<Object?> _cityLabelsSecondaryFilter = [
    'all',
    _cityLabelsFilter,
    ['==', ['get', 'isPrimary'], false],
  ];
  // Every numeric zoom value in this file's style expressions is stated in
  // *logical* zoom (flutter_map's/GisArchiveInfo's 256px-tile convention,
  // matching FlutterMapEngine's _AgronomicReferencePainter constants
  // exactly) minus [_zoomConventionOffset] (1) — MapLibre's `['zoom']`
  // expression operand always evaluates against the *native* camera zoom
  // (512px-tile convention, see [_toEngineZoom]), so a threshold meant to
  // read as "logical zoom 7.7" must be written as 6.7 here. Without this,
  // every zoom-gated reference layer (department boundaries, provincial
  // roads, secondary city labels, city circle/label opacity) appeared one
  // full logical zoom level later than FlutterMapEngine.
  static const List<Object?> _cityLabelsPrimaryOpacity = [
    'interpolate', ['linear'], ['zoom'], 4.0, 0.78, 6.5, 0.96,
  ];
  static const List<Object?> _cityLabelsSecondaryOpacity = [
    'interpolate', ['linear'], ['zoom'], 6.7, 0.0, 8.4, 0.96,
  ];

  // Matches _AgronomicReferencePainter: cityOpacity = _labelOpacity(zoom) *
  // _cityVisibility(city), where primary cities (La Plata, Mar del Plata,
  // Bahía Blanca) are always fully visible and the rest fade in between
  // zoom 7.7 and 9.4 (logical — 6.7/8.4 native, see the offset note above).
  // Reused by both the city circles and the city label icons so they never
  // appear/disappear independently of each other.
  static const List<Object?> _cityOpacityExpression = [
    '*',
    ['interpolate', ['linear'], ['zoom'], 4.0, 0.78, 6.5, 0.96],
    [
      'case',
      ['get', 'isPrimary'],
      1.0,
      ['interpolate', ['linear'], ['zoom'], 6.7, 0.0, 8.4, 1.0],
    ],
  ];

  /// Renders (via [_renderCityLabelBadge]) and registers via `addImage` any
  /// city-name label not already cached, then (re)creates the
  /// `_refCityLabelsId` symbol layer via `addLayer` if it isn't there yet.
  ///
  /// This layer is deliberately **not** part of the style JSON built in
  /// [_buildStyle], unlike the rest of the reference basemap. It used to
  /// be, styled with a data-driven `icon-image: ['get', 'labelImage']` —
  /// every image registered with no error (confirmed by pulling one off
  /// the device and inspecting it: a correctly rendered "Azul" bitmap,
  /// halo and all), but the labels never rendered regardless. Moving the
  /// exact same data-driven expression to a layer added via
  /// `controller.addLayer` (the mechanism the measurement vertex badges
  /// and personal markers already use successfully for their own
  /// data-driven `icon-image`) fixed it — something about a data-driven
  /// icon-image specifically inside a layer parsed from a full style
  /// document doesn't work the same way on this native SDK version.
  ///
  /// `addLayer`'s call fails the same "style not ready"/"layer already
  /// exists" way `addImage` can, so both the registration and the
  /// layer-creation below are best-effort and safe to retry — see
  /// [_pushStyle] for why `_registeredCityLabelImages`/
  /// [_cityLabelsLayerAdded] get reset there.
  Future<void> _ensureCityLabelImagesRegistered(
    maplibre.MapLibreMapController controller,
  ) async {
    for (final city in _referenceCities) {
      final imageName = _cityLabelImageName(city.name, city.isPrimary);
      if (_registeredCityLabelImages.contains(imageName)) continue;
      try {
        final bytes = await _renderCityLabelBadge(city.name, city.isPrimary);
        await controller.addImage(imageName, bytes);
        // Only mark it done *after* addImage succeeds — see [_pushStyle]'s
        // doc comment for why marking it before attempting the call would
        // have permanently skipped every retry for a label that actually
        // never got added.
        _registeredCityLabelImages.add(imageName);
      } catch (_) {
        // Retried the next time this is called (see onStyleLoadedCallback
        // in buildMapSurface, and _pushStyle/setPersonalMarkers) — not a
        // real failure, just means the style wasn't ready yet.
      }
    }
    if (!_cityLabelsLayerAdded && _registeredCityLabelImages.isNotEmpty) {
      // Set *before* the await, not after — _ensureCityLabelImagesRegistered
      // runs concurrently from more than one call site (_pushStyle and
      // setPersonalMarkers, both un-awaited), and marking this only on
      // success left a window where two concurrent calls both saw `false`
      // and both tried to add the same layer — caught
      // (CannotAddLayerException) but wasteful, and briefly left the flag
      // saying "not added" even though it, in fact, just had been.
      _cityLabelsLayerAdded = true;
      try {
        await controller.addLayer(
          _refSourceId,
          _refCityLabelsId,
          maplibre.SymbolLayerProperties(
            iconImage: const [maplibre.Expressions.get, 'labelImage'],
            // Matches _drawCityLabels' `offset.dx + 5, offset.dy -
            // height/2` positioning — 'left' anchors vertically centered
            // at the point, and the 5px gap is baked into the bitmap's
            // left padding (see _renderCityLabelBadge) instead of an
            // icon-offset, so it survives regardless of icon-size.
            iconAnchor: 'left',
            iconAllowOverlap: true,
            iconIgnorePlacement: true,
            // Primary cities (La Plata, Mar del Plata, Bahía Blanca):
            // always visible from zoom 5, matching _labelOpacity(zoom).
            iconOpacity: _cityLabelsPrimaryOpacity,
          ),
          enableInteraction: false,
          filter: _cityLabelsPrimaryFilter,
        );
        unawaited(
          controller.setLayerVisibility(
            _refCityLabelsId,
            _referenceBasemapVisible,
          ),
        );
      } catch (e) {
        // "Already exists" here means a concurrent call (see the field doc
        // comment above) won the race and added it first — the layer is
        // there either way, so leave the optimistic `true` from above
        // alone. Anything else (most likely "style not ready") means it
        // genuinely isn't there yet; reset so the next call retries.
        if (!e.toString().contains('already exists')) {
          _cityLabelsLayerAdded = false;
        }
      }
    }
    if (!_cityLabelsSecondaryLayerAdded && _registeredCityLabelImages.isNotEmpty) {
      _cityLabelsSecondaryLayerAdded = true;
      try {
        await controller.addLayer(
          _refSourceId,
          _refCityLabelsSecondaryId,
          maplibre.SymbolLayerProperties(
            iconImage: const [maplibre.Expressions.get, 'labelImage'],
            iconAnchor: 'left',
            // FlutterMapEngine's _drawCityLabels keeps an `occupiedLabels`
            // list and skips any label whose bounds overlap one already
            // placed (cities processed primary-first, so secondary names
            // never cover each other or a primary one). MapLibre's default
            // collision (allowOverlap/ignorePlacement both false) is the
            // native equivalent for this layer — first-placed symbol wins,
            // later overlapping ones are hidden — and this layer is added
            // *after* the primary layer below, so primary icons already
            // occupy their space by the time secondary placement runs.
            // (Primary itself stays allowOverlap:true — it must never be
            // hidden, and with only 3 fixed, spread-out cities it never
            // needs to be.)
            iconAllowOverlap: false,
            iconIgnorePlacement: false,
            // Secondary cities: hidden below zoom 7.7, fading in through
            // 9.4 — matches _cityVisibility's non-primary branch. A
            // separate layer + plain interpolate (rather than one shared
            // layer with a `case`/isPrimary-branching expression) so this
            // can't fail as a unit with the always-visible primary layer.
            iconOpacity: _cityLabelsSecondaryOpacity,
          ),
          enableInteraction: false,
          minzoom: 6.7,
          filter: _cityLabelsSecondaryFilter,
        );
        unawaited(
          controller.setLayerVisibility(
            _refCityLabelsSecondaryId,
            _referenceBasemapVisible,
          ),
        );
      } catch (e) {
        if (!e.toString().contains('already exists')) {
          _cityLabelsSecondaryLayerAdded = false;
        }
      }
    }
    // If the layer already existed and new labels were just registered
    // (e.g. a city name that hadn't been seen yet), nothing else is
    // needed — the layer already reads `labelImage` per-feature from the
    // source, no separate refresh required.
  }

  String _cityLabelImageName(String name, bool isPrimary) {
    final safeName = name.hashCode.toRadixString(36);
    return 'city-label-$safeName-${isPrimary ? 'p' : 's'}';
  }

  /// Matches _AgronomicReferencePainter._drawCityLabels' halo-then-fill
  /// text technique and exact styling (color/size/weight/halo width), just
  /// rasterized ahead of time instead of drawn every frame. A 5px transparent
  /// left margin reproduces that method's `offset.dx + 5` gap from the
  /// city dot without needing an icon-offset (see [_refCityLabelsId]).
  Future<Uint8List> _renderCityLabelBadge(String name, bool isPrimary) async {
    const leftPadding = 5.0;
    final haloWidth = isPrimary ? 5.0 : 4.5;
    final textStyle = TextStyle(
      color: const Color(0xFF29312C),
      fontSize: isPrimary ? 16 : 14.5,
      fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w600,
      height: 1.05,
    );
    final textPainter = TextPainter(
      text: TextSpan(text: name, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final haloPainter = TextPainter(
      text: TextSpan(
        text: name,
        style: textStyle.copyWith(
          foreground: Paint()
            ..color = const Color(0xFFFCFCFA)
            ..style = PaintingStyle.stroke
            ..strokeWidth = haloWidth
            ..strokeJoin = StrokeJoin.round,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final width = (leftPadding + textPainter.width + haloWidth).ceil();
    final height = (textPainter.height + haloWidth * 2).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final textOffset = Offset(leftPadding + haloWidth / 2, haloWidth);
    haloPainter.paint(canvas, textOffset);
    textPainter.paint(canvas, textOffset);

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Map<String, Object?> _buildReferenceGeoJson(Map<String, dynamic> layers) {
    // `category` is what each line layer's filter below matches on. Without
    // it every line feature (boundaries, rivers, roads) is indistinguishable
    // once merged into this single source, so a layer filtered only by
    // `$type == LineString` draws *all* categories — e.g. national-roads
    // (drawn last, opaque brown) painting directly over the river lines
    // underneath it, making rivers look missing even though the geometry is
    // there.
    List<Object?> lineFeatures(String key) {
      final lines = (layers[key] as List<dynamic>? ?? const []);
      return [
        for (final line in lines)
          {
            'type': 'Feature',
            'properties': {'category': key},
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
            'labelImage': _cityLabelImageName(
              city['name'] as String,
              city['importance'] == 'primary',
            ),
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
    unawaited(_replaceMarkerSymbols(controller, markers));
    // GisMapScreen calls setPersonalMarkers on every rebuild, which is what
    // makes _replaceMarkerSymbols' own "not initialized yet" race
    // self-healing (see its doc comment) — piggybacking city label
    // registration on the same reliably-repeated call gives it the same
    // property. The `_pushStyle`/`onStyleLoadedCallback` attempts alone
    // were not enough in testing: this is a cheap no-op once every label is
    // already registered (a Set lookup per city), so calling it here on
    // every rebuild isn't wasteful.
    unawaited(_ensureCityLabelImagesRegistered(controller));
  }

  /// Matches FlutterMapEngine's personal-marker widget exactly (see the
  /// `MarkerLayer`/`Material` in `GisMapScreen._buildMap`): a white circle
  /// badge with a soft drop shadow and the marker's category icon in red,
  /// anchored at the bottom of a 44x44 box (`Alignment.bottomCenter`) so the
  /// pin's bottom point — not its center — sits on the geographic
  /// coordinate. Rendered as a bitmap (same Canvas/TextPainter technique as
  /// the measurement vertex badges) since MapLibre's Circle annotation has
  /// no icon support and this needs to stay fully offline.
  Future<void> _replaceMarkerSymbols(
    maplibre.MapLibreMapController controller,
    List<SoilMapMarkerPin> markers,
  ) async {
    // setPersonalMarkers can be (and is) called from GisMapScreen's very
    // first _buildMap rebuild, which can land before the map's style has
    // finished loading — the plugin's SymbolManager isn't created until
    // then, and addSymbols/addImage throw in that window ("This Annotation
    // Manager has not been initialized"). That's expected and transient,
    // not a real failure: the next rebuild (setPersonalMarkers is called on
    // every one) retries with the exact same markers once the style is
    // ready. Swallowing it here just avoids an unhandled-exception log spam
    // for a race that resolves itself.
    try {
      await _replaceMarkerSymbolsUnsafe(controller, markers);
    } catch (_) {
      // Retried on the next setPersonalMarkers call — see above.
    }
  }

  List<SoilMapMarkerPin> _lastPushedMarkers = const <SoilMapMarkerPin>[];

  bool _sameMarkers(List<SoilMapMarkerPin> a, List<SoilMapMarkerPin> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final markerA = a[i];
      final markerB = b[i];
      if (markerA.id != markerB.id ||
          markerA.point.latitude != markerB.point.latitude ||
          markerA.point.longitude != markerB.point.longitude ||
          markerA.icon != markerB.icon) {
        return false;
      }
    }
    return true;
  }

  Future<void> _replaceMarkerSymbolsUnsafe(
    maplibre.MapLibreMapController controller,
    List<SoilMapMarkerPin> markers,
  ) async {
    // GisMapScreen calls setPersonalMarkers on every rebuild (see
    // setPersonalMarkers' doc comment), which previously meant every
    // rebuild — selecting a marker, opening/closing a sheet, anything —
    // removed every symbol and re-added them all, with a visible blank gap
    // in between (two native round-trips). FlutterMapEngine's markers are
    // plain Flutter widgets rebuilt in place, so it never had this. Skipping
    // when nothing actually changed removes the flicker without touching
    // how a real add/move/remove is applied.
    if (_sameMarkers(_lastPushedMarkers, markers)) return;
    if (_markerSymbols.isNotEmpty) {
      await controller.removeSymbols(_markerSymbols);
      _markerSymbols.clear();
    }
    if (markers.isEmpty) {
      _lastPushedMarkers = const <SoilMapMarkerPin>[];
      return;
    }
    for (final marker in markers) {
      final imageName = _markerBadgeImageName(marker.icon);
      if (_registeredMarkerBadgeImages.add(imageName)) {
        final bytes = await _renderMarkerBadge(marker.icon);
        await controller.addImage(imageName, bytes);
      }
    }
    final added = await controller.addSymbols(
      [
        for (final marker in markers)
          maplibre.SymbolOptions(
            geometry: _toMaplibreLatLng(marker.point),
            iconImage: _markerBadgeImageName(marker.icon),
            iconAnchor: 'bottom',
          ),
      ],
      [for (final marker in markers) {'type': 'marker', 'markerId': marker.id}],
    );
    _markerSymbols.addAll(added);
    // Only recorded once `addSymbols` actually succeeds — if it throws
    // (style not ready yet, see the try/catch in _replaceMarkerSymbols),
    // _lastPushedMarkers must stay behind so the next rebuild's identical
    // call isn't skipped by _sameMarkers and retries instead.
    _lastPushedMarkers = List<SoilMapMarkerPin>.unmodifiable(markers);
  }

  String _markerBadgeImageName(IconData icon) =>
      'marker-badge-${icon.fontFamily}-${icon.fontPackage}-${icon.codePoint}';

  static const double _markerBoxSize = 44;
  static const double _markerCircleDiameter = 36;
  static const double _markerCircleCenterY = 22;

  Future<Uint8List> _renderMarkerBadge(IconData icon) async {
    // Matches [_renderVertexBadge]/[_renderCityLabelBadge]: `addImage` has
    // no `pixelRatio` parameter, so MapLibre falls back to the device's
    // actual screen density when interpreting these bytes — a bitmap
    // rasterized at exactly `_markerBoxSize` raw pixels (no DPR scaling)
    // was read back as `_markerBoxSize / density` dp, which is why these
    // markers rendered visibly smaller than FlutterMapEngine's 44×44dp
    // `MarkerLayer` widget on any device denser than 1x.
    final pixelRatio = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .devicePixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(pixelRatio);
    const center = Offset(_markerBoxSize / 2, _markerCircleCenterY);

    // Soft drop shadow approximating the Material `elevation: 2` +
    // `shadowColor: colorScheme.shadow.withValues(alpha: 0.18)` FlutterMapEngine
    // uses for this same badge.
    final shadowPaint = ui.Paint()
      ..color = const Color(0x2E000000)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    canvas.drawCircle(
      center + const Offset(0, 1.5),
      _markerCircleDiameter / 2,
      shadowPaint,
    );

    canvas.drawCircle(
      center,
      _markerCircleDiameter / 2,
      ui.Paint()..color = const Color(0xFFFFFFFF),
    );

    final iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 22,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: const Color(0xFFD11313),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    iconPainter.paint(
      canvas,
      center - Offset(iconPainter.width / 2, iconPainter.height / 2),
    );

    final picture = recorder.endRecording();
    final physicalBoxSize = (_markerBoxSize * pixelRatio).round();
    final image = await picture.toImage(physicalBoxSize, physicalBoxSize);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
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
      if (_accuracyBorder != null) {
        await controller.removeLine(_accuracyBorder!);
        _accuracyBorder = null;
      }
      return;
    }

    // Matches _CurrentLocationLayer's dot exactly: a 16px `_locationBlue`
    // circle with a 3px white border (circleRadius here is the *inner*
    // radius, and circleStrokeWidth draws outward from it, same as that
    // widget's DecoratedBox — the box-shadow it also draws has no
    // equivalent on a native Circle annotation and is the one part of this
    // marker left un-matched).
    if (_locationCircle == null) {
      _locationCircle = await controller.addCircle(
        maplibre.CircleOptions(
          geometry: _toMaplibreLatLng(point),
          circleRadius: 8,
          circleColor: '#1976D2',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
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
      if (_accuracyBorder != null) {
        await controller.removeLine(_accuracyBorder!);
        _accuracyBorder = null;
      }
      return;
    }
    // Matches _CurrentLocationLayer's CircleMarker: fill alpha 0.12, plus a
    // border ring at alpha 0.42 width 1 — the fill alone (still all the
    // MapLibre accuracy circle drew before this) reads noticeably softer
    // without that ring.
    final ring = _geodesicCircle(point, accuracyMeters);
    if (_accuracyFill == null) {
      _accuracyFill = await controller.addFill(
        maplibre.FillOptions(
          geometry: [ring],
          fillColor: '#1976D2',
          fillOpacity: 0.12,
        ),
      );
    } else {
      await controller.updateFill(
        _accuracyFill!,
        maplibre.FillOptions(geometry: [ring]),
      );
    }
    if (_accuracyBorder == null) {
      _accuracyBorder = await controller.addLine(
        maplibre.LineOptions(
          geometry: ring,
          lineColor: '#1976D2',
          lineOpacity: 0.42,
          lineWidth: 1,
        ),
      );
    } else {
      await controller.updateLine(
        _accuracyBorder!,
        maplibre.LineOptions(geometry: ring),
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

  /// MapLibre-only (not part of [SoilMapEngine], same reasoning as
  /// [setVertexBadgeSurfaceColor]): whether the vertices [setMeasurementGeometry]
  /// pushes should be draggable. FlutterMapEngine's equivalent for a
  /// non-actively-edited measurement is `_SavedMeasurementsLayer`, a
  /// separate `IgnorePointer`-wrapped static layer with no vertex handles
  /// at all — MapLibre instead reuses [setMeasurementGeometry] to keep
  /// showing a just-closed measurement (see `_finishMeasurement`'s doc
  /// comment in gis_map_screen.dart), so without this its vertices stayed
  /// draggable even though there's no editor UI open to reflect the drag.
  /// Defaults to `true` (today's behavior) until GisMapScreen says
  /// otherwise.
  bool _measurementInteractive = true;

  void setMeasurementInteractive(bool interactive) {
    _measurementInteractive = interactive;
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
    int? draggedVertexIndex,
  }) {
    _onVertexTap = onVertexTap;
    _onVertexDragStart = onVertexDragStart;
    _onVertexDragUpdate = onVertexDragUpdate;
    _onVertexDragEnd = onVertexDragEnd;

    final colorUnchanged = color == _lastMeasurementColor;
    final draggedVertexUnchanged =
        draggedVertexIndex == _lastDraggedVertexIndex;
    if (_listEquals(distancePoints, _lastDistancePoints) &&
        _listEquals(areaPoints, _lastAreaPoints) &&
        colorUnchanged &&
        draggedVertexUnchanged) {
      return;
    }

    _lastDistancePoints = List.of(distancePoints);
    _lastAreaPoints = List.of(areaPoints);
    _lastMeasurementColor = color;
    _lastDraggedVertexIndex = draggedVertexIndex;

    final controller = _controller;
    if (controller == null) return;

    _pendingDistancePoints = distancePoints;
    _pendingAreaPoints = areaPoints;
    _pendingColor = color;
    _pendingDraggedVertexIndex = draggedVertexIndex;
    _pendingHasDraggedVertexIndex = true;
    if (!_geometryUpdateInFlight) {
      unawaited(_drainMeasurementUpdates(controller));
    }
  }

  /// Drains [_pendingDistancePoints]/[_pendingAreaPoints]/[_pendingColor],
  /// applying [_applyMeasurementGeometry] to the latest pending request
  /// until none are left. See the [_geometryUpdateInFlight] field doc
  /// comment for why this exists — it is backpressure, not a timing fix.
  Future<void> _drainMeasurementUpdates(
    maplibre.MapLibreMapController controller,
  ) async {
    _geometryUpdateInFlight = true;
    try {
      while (_pendingDistancePoints != null || _pendingAreaPoints != null) {
        final distancePoints = _pendingDistancePoints ?? const [];
        final areaPoints = _pendingAreaPoints ?? const [];
        final color = _pendingColor ?? _lastMeasurementColor;
        final draggedVertexIndex = _pendingHasDraggedVertexIndex
            ? _pendingDraggedVertexIndex
            : null;
        _pendingDistancePoints = null;
        _pendingAreaPoints = null;
        _pendingColor = null;
        _pendingDraggedVertexIndex = null;
        _pendingHasDraggedVertexIndex = false;
        if (color == null) continue;
        try {
          await _applyMeasurementGeometry(
            controller,
            distancePoints,
            areaPoints,
            color,
            draggedVertexIndex,
          );
          _measurementApplyFailureStreak = 0;
        } catch (_) {
          // A failed native apply must not be masked by the dedup check in
          // setMeasurementGeometry: _lastDistancePoints/_lastAreaPoints were
          // already updated optimistically (needed so a fast vertex drag
          // doesn't queue up redundant native work — see
          // _geometryUpdateInFlight's doc comment), so without retrying here
          // a later call with that same already-failed geometry would look
          // "unchanged" and dedup away, leaving the map missing it
          // permanently instead of just for one frame. Bounded so a
          // persistently failing apply (e.g. a disposed controller) can't
          // spin forever.
          _measurementApplyFailureStreak++;
          if (_measurementApplyFailureStreak <= 3) {
            _pendingDistancePoints = distancePoints;
            _pendingAreaPoints = areaPoints;
            _pendingColor = color;
            _pendingDraggedVertexIndex = draggedVertexIndex;
            _pendingHasDraggedVertexIndex = true;
          } else {
            _measurementApplyFailureStreak = 0;
          }
        }
      }
    } finally {
      _geometryUpdateInFlight = false;
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

  /// The single source of truth for measurement geometry: builds one
  /// GeoJSON `FeatureCollection` containing every vertex point *and* the
  /// boundary (LineString for distance mode, Polygon for area mode with
  /// >=3 points) together, then writes it with **one**
  /// `setGeoJsonSource` call. That one call is what makes vertex, line and
  /// fill atomic with respect to each other — MapLibre's native renderer
  /// can only ever see the complete old state or the complete new state,
  /// never a partial mix, because there is only one source instead of the
  /// three independently-updated ones (Symbol/Fill/Line via their own
  /// AnnotationManagers) this replaced. See the Etapa 3 report's root
  /// cause investigation.
  Future<void> _applyMeasurementGeometry(
    maplibre.MapLibreMapController controller,
    List<app_geo.LatLng> distancePoints,
    List<app_geo.LatLng> areaPoints,
    Color color,
    int? draggedVertexIndex,
  ) async {
    final hex = _toHexColor(color);
    final isArea = areaPoints.isNotEmpty;
    final points = isArea ? areaPoints : distancePoints;

    // Numbered vertex badges — matches _MeasurementLayer._buildEditableVertexMarker
    // (labels '1', '2', ... in the app's selected measurement color), but
    // rendered as a bitmap via Canvas/TextPainter and shown through
    // addImage + a data-driven `iconImage` on the vertex layer: MapLibre's
    // own glyph system needs a `glyphs` PBF source we don't bundle (kept
    // fully offline — see the Etapa 3 report), while Flutter's own text
    // rendering needs nothing extra and produces the same visual result for
    // a fixed short label. Registered once per distinct number+color+state
    // and reused after that, same as before this rewrite.
    for (var i = 0; i < points.length; i++) {
      final dragged = i == draggedVertexIndex;
      final imageName = _vertexBadgeImageName(i + 1, hex, dragged: dragged);
      if (_registeredBadgeImages.add(imageName)) {
        final bytes = await _renderVertexBadge(
          '${i + 1}',
          color,
          dragged: dragged,
        );
        await controller.addImage(imageName, bytes);
      }
    }

    final features = <Map<String, dynamic>>[];
    if (isArea && points.length >= 3) {
      final ring = [
        for (final p in points) [p.longitude, p.latitude],
        [points.first.longitude, points.first.latitude],
      ];
      features.add({
        'type': 'Feature',
        'id': 'boundary',
        'properties': {'kind': 'boundary', 'color': hex},
        'geometry': {
          'type': 'Polygon',
          'coordinates': [ring],
        },
      });
    } else if (points.length >= 2) {
      features.add({
        'type': 'Feature',
        'id': 'boundary',
        'properties': {'kind': 'boundary', 'color': hex},
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in points) [p.longitude, p.latitude]],
        },
      });
    }

    _vertexFeatureIdToIndex.clear();
    for (var i = 0; i < points.length; i++) {
      final featureId = 'vertex-$i';
      _vertexFeatureIdToIndex[featureId] = i;
      final dragged = i == draggedVertexIndex;
      features.add({
        'type': 'Feature',
        'id': featureId,
        'properties': {
          'kind': 'vertex',
          'index': i,
          'draggable': _measurementInteractive,
          'badge': _vertexBadgeImageName(i + 1, hex, dragged: dragged),
          // Matches _buildEditableVertexMarker's exact widget sizes
          // (isDragged ? 44 : (isFirst ? 38 : 30)) relative to the badge
          // bitmap's design size (_vertexBadgeDesignDiameter, 72dp) — the
          // bitmap itself is rendered at that many *physical* pixels (see
          // _renderVertexBadge) so this fraction yields the correct dp size
          // on any device pixel ratio, matching FlutterMapEngine exactly.
          'iconSize': dragged
              ? 44 / _vertexBadgeDesignDiameter
              : (i == 0 ? 38 / _vertexBadgeDesignDiameter : 30 / _vertexBadgeDesignDiameter),
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [points[i].longitude, points[i].latitude],
        },
      });
    }

    final collection = {'type': 'FeatureCollection', 'features': features};
    if (!_measurementLayersReady) {
      await _createMeasurementLayers(controller, collection);
      _measurementLayersReady = true;
    } else {
      await controller.setGeoJsonSource(_measurementSourceId, collection);
    }
  }

  static const List<Object?> _measurementBoundaryFilter = [
    '==',
    ['get', 'kind'],
    'boundary',
  ];
  static const List<Object?> _measurementVertexFilter = [
    '==',
    ['get', 'kind'],
    'vertex',
  ];

  /// Creates the measurement source and its 3 style layers once. Order
  /// matters for two reasons: (1) later layers render on top, so the
  /// vertex layer must be added last for badges to appear above the fill;
  /// (2) hit-testing (`firstFeatureOnLayers` on the native side) queries
  /// layers topmost-first and returns the first match, so the same
  /// ordering is what makes a tap exactly on a vertex resolve to that
  /// vertex instead of the fill/line beneath it — no separate
  /// `annotationConsumeTapEvents` exclusion is needed this time because
  /// fill/line are created with `enableInteraction: false` outright (they
  /// have nothing meaningful to do with a tap; mid-segment insertion needs
  /// those taps to fall through to `onMapClick` instead, exactly as
  /// before).
  Future<void> _createMeasurementLayers(
    maplibre.MapLibreMapController controller,
    Map<String, dynamic> collection,
  ) async {
    await controller.addGeoJsonSource(_measurementSourceId, collection);
    await controller.addLayer(
      _measurementSourceId,
      _measurementFillLayerId,
      const maplibre.FillLayerProperties(
        fillColor: [maplibre.Expressions.get, 'color'],
        fillOpacity: 0.25,
      ),
      enableInteraction: false,
      filter: _measurementBoundaryFilter,
    );
    await controller.addLayer(
      _measurementSourceId,
      _measurementLineLayerId,
      const maplibre.LineLayerProperties(
        lineColor: [maplibre.Expressions.get, 'color'],
        lineWidth: 3,
      ),
      enableInteraction: false,
      filter: _measurementBoundaryFilter,
    );
    await controller.addLayer(
      _measurementSourceId,
      _measurementSymbolLayerId,
      const maplibre.SymbolLayerProperties(
        iconImage: [maplibre.Expressions.get, 'badge'],
        iconSize: [maplibre.Expressions.get, 'iconSize'],
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      enableInteraction: true,
      filter: _measurementVertexFilter,
    );
  }

  /// Design (dp) diameter the badge bitmap is authored at — `iconSize`
  /// fractions elsewhere in this file (e.g. `30 / _vertexBadgeDesignDiameter`)
  /// are relative to this, not to the bitmap's raw pixel size. The bitmap
  /// itself is rasterized at `_vertexBadgeDesignDiameter * devicePixelRatio`
  /// physical pixels (see [_renderVertexBadge]) so it displays at exactly
  /// this many *dp*, matching `_buildEditableVertexMarker`'s Flutter-widget
  /// sizing regardless of the device's screen density.
  static const double _vertexBadgeDesignDiameter = 72;

  /// Fill/border used for the dragged visual state, matching
  /// `_AreaVertexHandle`'s `colorScheme.error`/`colorScheme.onError` — this
  /// engine has no `BuildContext`/theme access (see `loadSoilPolygonsLayer`,
  /// which receives its theme colors as explicit parameters instead), so
  /// the Material 3 baseline error palette is used directly rather than
  /// threading the app's actual `ColorScheme` through just for this.
  static const Color _draggedVertexColor = Color(0xFFB3261E);
  static const Color _draggedVertexBorderColor = Color(0xFFFFFFFF);

  /// Normal (non-dragged) vertex badge border — matches
  /// `_AreaVertexHandle`'s `colorScheme.surface`, which needs the app's
  /// actual theme and so can't be a fixed constant like
  /// [_draggedVertexColor] above. Not part of [SoilMapEngine] — GisMapScreen
  /// calls this directly on the concrete `MapLibreEngine` (same pattern as
  /// its `(_mapEngine as FlutterMapEngine).controller` casts elsewhere)
  /// rather than threading a new theme parameter through the shared
  /// interface just for this one color.
  Color _vertexBadgeBorderColor = const Color(0xFFFFFFFF);

  void setVertexBadgeSurfaceColor(Color color) {
    if (_vertexBadgeBorderColor == color) return;
    _vertexBadgeBorderColor = color;
    // Badge bitmaps are cached per number+color+drag-state (see
    // _registeredBadgeImages below) and don't encode the border color in
    // that cache key, so every already-registered badge now has the wrong
    // border baked in — clear them so the next push re-renders with the
    // new one.
    _registeredBadgeImages.clear();
  }

  String _vertexBadgeImageName(
    int number,
    String colorHex, {
    bool dragged = false,
  }) => 'vertex-badge-$number-$colorHex${dragged ? '-drag' : ''}';

  /// Renders a small numbered circular badge to a PNG, purely with
  /// Flutter's own Canvas/TextPainter — no MapLibre glyph/font resource
  /// needed, so this stays fully offline.
  Future<Uint8List> _renderVertexBadge(
    String label,
    Color color, {
    bool dragged = false,
  }) async {
    const double diameter = _vertexBadgeDesignDiameter;
    final pixelRatio = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .devicePixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(pixelRatio);
    final fillColor = dragged ? _draggedVertexColor : color;
    final backgroundPaint = ui.Paint()..color = fillColor;
    canvas.drawCircle(
      const Offset(diameter / 2, diameter / 2),
      diameter / 2 - 2,
      backgroundPaint,
    );
    final borderPaint = ui.Paint()
      ..color = dragged ? _draggedVertexBorderColor : _vertexBadgeBorderColor
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = dragged ? 4 : 3;
    canvas.drawCircle(
      const Offset(diameter / 2, diameter / 2),
      diameter / 2 - 2,
      borderPaint,
    );
    // MeasurementColorOption has exactly 3 fixed colors, and only orange
    // pairs with black text (blue/red both pair with white) — matched by
    // hex value instead of importing that model, keeping this engine
    // decoupled from it (see the border-color note above). White text on
    // orange read poorly compared to FlutterMapEngine's `measurementOnColor`
    // black.
    // Dragged state always uses colorScheme.onError (white) in
    // FlutterMapEngine, regardless of measurement color — only the
    // non-dragged case follows measurementOnColor.
    final isOrangeMeasurementColor =
        !dragged && _toHexColor(color) == '#ff9800';
    final textColor = isOrangeMeasurementColor
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    final haloColor = isOrangeMeasurementColor
        ? const Color(0x99FFFFFF)
        : const Color(0x99000000);
    final haloPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = haloColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          color: textColor,
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
    final physicalDiameter = (diameter * pixelRatio).round();
    final image = await picture.toImage(physicalDiameter, physicalDiameter);
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
  ///
  /// Also a chokepoint for (re-)registering city label images (see
  /// [_ensureCityLabelImagesRegistered]) — deliberately called *after*
  /// `setStyle`, not before. `setStyle` replaces the native `Style` object
  /// wholesale, and confirmed by testing: any image added with `addImage`
  /// before that call is gone once the new style is applied — so
  /// registering first (the original order here) silently threw away every
  /// registration on the very next style push, and [_registeredCityLabelImages]
  /// then wrongly believed those images still existed and never retried.
  Future<void> _pushStyle() async {
    final controller = _controller;
    if (controller != null) {
      // Whatever was in _registeredCityLabelImages/_cityLabelsLayerAdded is
      // about to be wrong — setStyle is a wholesale replacement, so any
      // image added (or layer added via addLayer) against the outgoing
      // style is gone. Forget both now so the re-registration right after
      // setStyle can't skip anything it (wrongly) believes is already
      // there.
      _registeredCityLabelImages.clear();
      _cityLabelsLayerAdded = false;
      _cityLabelsSecondaryLayerAdded = false;
      await controller.setStyle(_buildStyle());
      await _ensureCityLabelImagesRegistered(controller);
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
      sources[_refSourceId] = {
        'type': 'geojson',
        'data': referenceGeoJson,
        // FlutterMapEngine's CustomPainter draws every source vertex
        // unconditionally, at every zoom. MapLibre's GeoJSON source
        // simplifies geometry per internal tile (default tolerance 0.375),
        // which at low zoom can collapse short arroyos entirely. tolerance:
        // 0 disables that simplification so small streams stay visible,
        // matching FlutterMapEngine.
        'tolerance': 0,
      };
      final refVisibility = _referenceBasemapVisible ? 'visible' : 'none';
      // Colors/widths/opacities below are read directly off
      // OfflineReferenceMapLayer's Paint objects (_linePaint calls in
      // _AgronomicReferencePainter) — same values, just expressed as
      // MapLibre `line-opacity` instead of an alpha channel baked into the
      // color, since MapLibre's hex colors here don't carry alpha.
      layers.addAll([
        {
          'id': _refProvincialBoundariesId,
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', ['get', 'category'], 'provincialBoundaries'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#AEB4AC',
            'line-width': 0.9,
            'line-opacity': 0.69,
          },
        },
        {
          // FlutterMapEngine fades this in smoothly between logical zoom 7.8
          // and 9 (_zoomOpacity(zoom, 7.8, 9)) rather than popping in at a
          // hard cutoff — matched with a `line-opacity` ramp instead of
          // relying on `minzoom` alone for the transition (minzoom is kept
          // too, as a cheap "don't even evaluate below this" floor). Values
          // are native zoom (logical - _zoomConventionOffset) — see the note
          // on _cityLabelsPrimaryOpacity.
          'id': _refDepartmentBoundariesId,
          'type': 'line',
          'source': _refSourceId,
          'minzoom': 6.8,
          'filter': ['==', ['get', 'category'], 'departmentBoundaries'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#CFD3CC',
            'line-width': 0.5,
            'line-opacity': [
              'interpolate', ['linear'], ['zoom'], 6.8, 0.0, 8.0, 0.56,
            ],
          },
        },
        // Rivers/roads are each drawn as a wider pale "casing" line
        // underneath a narrower colored line on top — that's what gives
        // them the halo look in FlutterMapEngine; a single line layer (what
        // this used before) reads visibly flatter/thinner.
        {
          'id': '$_refRiversId-casing',
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', ['get', 'category'], 'majorRivers'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#F7FBFC',
            'line-width': 3.0,
            'line-opacity': 0.72,
          },
        },
        {
          'id': _refRiversId,
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', ['get', 'category'], 'majorRivers'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#6BA9CC',
            'line-width': 1.55,
            'line-opacity': 0.89,
          },
        },
        {
          'id': '$_refNationalRoadsId-casing',
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', ['get', 'category'], 'nationalRoads'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#FFF9F5',
            'line-width': 3.4,
            'line-opacity': 0.91,
          },
        },
        {
          'id': _refNationalRoadsId,
          'type': 'line',
          'source': _refSourceId,
          'filter': ['==', ['get', 'category'], 'nationalRoads'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#BD5738',
            'line-width': 1.65,
            'line-opacity': 0.90,
          },
        },
        {
          // Native zoom (logical - _zoomConventionOffset), same as
          // _refDepartmentBoundariesId above — logical 8.2/9.5.
          'id': '$_refProvincialRoadsId-casing',
          'type': 'line',
          'source': _refSourceId,
          'minzoom': 7.2,
          'filter': ['==', ['get', 'category'], 'provincialRoads'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#FFF9F5',
            'line-width': 2.65,
            'line-opacity': [
              'interpolate', ['linear'], ['zoom'], 7.2, 0.0, 8.5, 0.85,
            ],
          },
        },
        {
          'id': _refProvincialRoadsId,
          'type': 'line',
          'source': _refSourceId,
          'minzoom': 7.2,
          'filter': ['==', ['get', 'category'], 'provincialRoads'],
          'layout': {'visibility': refVisibility},
          'paint': {
            'line-color': '#D77A59',
            'line-width': 1.15,
            'line-opacity': [
              'interpolate', ['linear'], ['zoom'], 7.2, 0.0, 8.5, 0.82,
            ],
          },
        },
        // _refCityCirclesId is NOT defined here — FlutterMapEngine draws
        // city dots in its "foreground" pass, *after* soil polygons (see
        // _AgronomicReferencePainter.paint's `!foreground`/`else` split and
        // GisMapScreen._buildMap's `children` order: reference lines, then
        // soil polygons, then OfflineReferenceMapLayer(foreground: true)).
        // Defining it in this list would put it before the soil-polygon
        // layers added below, letting a polygon's fill cover a city dot —
        // added after them instead, near the end of this method.
        // _refCityLabelsId is NOT defined here — see
        // _ensureCityLabelImagesRegistered/_addCityLabelsLayerIfNeeded for
        // why (a data-driven `icon-image` on a layer embedded in this style
        // JSON silently never rendered anything, despite the referenced
        // image existing and loading with no error — confirmed by direct
        // bitmap inspection during the visual-parity investigation; the
        // exact same expression works when the layer is instead added via
        // `controller.addLayer`, which every other data-driven-icon layer
        // in this engine already uses).
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
          // Matches _GisPolygonStyle.fromColorScheme's normalBorder
          // (colorScheme.primary, borderStrokeWidth: 2).
          'id': _outlineLayerId,
          'type': 'line',
          'source': _sourceId,
          'source-layer': layerName,
          'layout': {
            'visibility': _soilPolygonsVisible ? 'visible' : 'none',
          },
          'paint': {'line-color': _normalFillColorHex, 'line-width': 2.0},
        },
        {
          // Matches _GisPolygonStyle.fromColorScheme's selectedBorder
          // (colorScheme.tertiary, borderStrokeWidth: 4) — FlutterMapEngine
          // draws the selected polygon's own border in the tertiary color at
          // double width instead of just filling it a different color, so
          // without this the selected feature never got a visibly thicker/
          // differently-colored outline here, only a filled interior.
          'id': _selectedOutlineLayerId,
          'type': 'line',
          'source': _sourceId,
          'source-layer': layerName,
          'filter': _selectionFilter(),
          'layout': {
            'visibility':
                _soilPolygonsVisible && _selectedFeatureId != null
                    ? 'visible'
                    : 'none',
          },
          'paint': {'line-color': _selectedFillColorHex, 'line-width': 4.0},
        },
      ]);
    }

    // City dots, added after (so drawn on top of) the soil-polygon layers
    // above — matches FlutterMapEngine's foreground pass. Same source/
    // paint as before, just relocated; see the comment left in its old spot.
    if (referenceGeoJson != null) {
      layers.add({
        'id': _refCityCirclesId,
        'type': 'circle',
        'source': _refSourceId,
        'filter': ['==', '\$type', 'Point'],
        'layout': {
          'visibility': _referenceBasemapVisible ? 'visible' : 'none',
        },
        'paint': {
          'circle-color': '#303632',
          'circle-radius': [
            'case', ['get', 'isPrimary'], 2.7, 2.3,
          ],
          'circle-opacity': _cityOpacityExpression,
        },
      });
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
      // Converted back to the app's logical (256px-tile) zoom convention —
      // see [_toEngineZoom]/[_toLogicalZoom].
      zoom: _toLogicalZoom(position.zoom),
      // Negated to match flutter_map's content-rotation convention — see
      // the sign note on [rotate].
      rotation: -position.bearing,
    );
  }

  maplibre.LatLng _toMaplibreLatLng(app_geo.LatLng point) {
    return maplibre.LatLng(point.latitude, point.longitude);
  }

  app_geo.LatLng _toLatLng2(maplibre.LatLng point) {
    return app_geo.LatLng(point.latitude, point.longitude);
  }
}
