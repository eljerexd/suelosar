import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:pmtiles/pmtiles.dart';

import '../gis_feature.dart';
import '../gis_layer.dart';
import '../native_map_source.dart';
import '../offline_reference_map_layer.dart';
import '../../models/saved_measurement.dart';
import '../../services/settings_service.dart';
import 'maplibre_measurement_data.dart';
import 'maplibre_province_highlight_data.dart';
import 'maplibre_geographic_annotations.dart';
import 'maplibre_reference_basemap.dart';
import 'maplibre_feature_selection.dart';
import '../measurement_render_style.dart';
import 'maplibre_measurement_styles.dart';
import 'serial_async_queue.dart';
import 'soil_map_engine.dart';

/// Native MapLibre renderer for soil PMTiles, reference geometry, geographic
/// annotations, and measurement geometry.
class MapLibreEngine implements SoilMapEngine {
  MapLibreEngine() {
    SettingsService.instance.addListener(_onAnnotationSettingsChanged);
  }

  static const String _fillSuffix = '-fill';
  static const String _outlineSuffix = '-outline';
  static const String _selectionSuffix = '-selection-fill';
  static const String _selectionOutlineSuffix = '-selection-outline';

  @visibleForTesting
  static double soilPolygonFillOpacityFor(TargetPlatform platform) => 0.10;

  @visibleForTesting
  static Color soilPolygonFillOutlineColor() => Colors.transparent;

  @visibleForTesting
  static double? soilPolygonOutlineWidthFor(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android => 1,
        TargetPlatform.windows => 1,
        _ => null,
      };

  @visibleForTesting
  static double? selectedSoilPolygonOutlineWidthFor(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android => 2,
        TargetPlatform.windows => 2,
        _ => null,
      };
  static final ml.Expression<bool> _noFeatureFilter = ml.Expression<bool>.raw([
    '==',
    r'$id',
    -1,
  ]);
  static const String _referenceBackgroundId = 'suelosar-transparent';
  static const String _cityAnnotationSourceId = 'suelosar-city-annotations';
  static const String _cityDotLayerId = 'suelosar-city-dots';
  static const String _citySecondaryDotLayerId = 'suelosar-city-secondary-dots';
  static const String _cityLabelLayerId = 'suelosar-city-labels';
  static const String _citySecondaryLabelLayerId =
      'suelosar-city-secondary-labels';
  static const List<String> _departmentLabelLayerIds = [
    'suelosar-department-labels',
    'suelosar-department-labels-zoom-77',
    'suelosar-department-labels-zoom-86',
    'suelosar-department-labels-zoom-94',
  ];
  static const Map<String, String> _administrativeBoundaryLayerIds = {
    'buenos_aires': 'suelosar-administrative-boundaries-buenos-aires',
    'santa_fe': 'suelosar-administrative-boundaries-santa-fe',
    'cordoba': 'suelosar-administrative-boundaries-cordoba',
  };
  static const String _personalMarkerSourceId =
      'suelosar-personal-marker-source';
  static const String _personalMarkerCircleLayerId =
      'suelosar-personal-marker-circles';
  static const String _personalMarkerLayerId = 'suelosar-personal-markers';
  static const String _locationSourceId = 'suelosar-current-location-source';
  static const String _locationAccuracyLayerId =
      'suelosar-current-location-accuracy';
  static const String _locationMarkerLayerId =
      'suelosar-current-location-marker';
  static const String _locationImageId = 'suelosar-current-location';
  static const String _activeMeasurementSourceId =
      'suelosar-measure-active-geometry';
  static const String _provinceHighlightSourceId =
      'suelosar-province-highlight-source';
  static const String _provinceHighlightFillId =
      'suelosar-province-highlight-fill';
  static const String _provinceHighlightOutlineId =
      'suelosar-province-highlight-outline';
  static const String _savedMeasurementSourceId =
      'suelosar-measure-saved-geometry';
  static const String _activeDistanceLineId =
      'suelosar-measure-active-distance-line';
  static const String _activeAreaFillId = 'suelosar-measure-active-area-fill';
  static const String _activeAreaOutlineId =
      'suelosar-measure-active-area-outline';
  static const String _activeVertexCircleId =
      'suelosar-measure-active-vertices';
  static const String _activeVertexLabelsId =
      'suelosar-measure-active-vertex-labels';
  static const String _savedAreaNormalId = 'suelosar-measure-saved-area-normal';
  static const String _savedAreaHoveredId =
      'suelosar-measure-saved-area-hovered';
  static const String _savedAreaSelectedId =
      'suelosar-measure-saved-area-selected';
  static const String _savedAreaLineNormalId =
      'suelosar-measure-saved-area-line-normal';
  static const String _savedAreaLineHoveredId =
      'suelosar-measure-saved-area-line-hovered';
  static const String _savedAreaLineSelectedId =
      'suelosar-measure-saved-area-line-selected';
  static const String _savedDistanceLineNormalId =
      'suelosar-measure-saved-distance-line-normal';
  static const String _savedDistanceLineHoveredId =
      'suelosar-measure-saved-distance-line-hovered';
  static const String _savedDistanceLineSelectedId =
      'suelosar-measure-saved-distance-line-selected';
  static const List<String> _measurementLayerOrderBottomToTop = [
    _activeAreaFillId,
    _savedAreaNormalId,
    _savedAreaHoveredId,
    _savedAreaSelectedId,
    _activeDistanceLineId,
    _activeAreaOutlineId,
    _savedAreaLineNormalId,
    _savedAreaLineHoveredId,
    _savedAreaLineSelectedId,
    _savedDistanceLineNormalId,
    _savedDistanceLineHoveredId,
    _savedDistanceLineSelectedId,
    _activeVertexCircleId,
    _activeVertexLabelsId,
  ];
  static const String _emptyFeatureCollection =
      '{"type":"FeatureCollection","features":[]}';
  static const Color _referenceBackgroundColor = Color(0xFFFAFAF8);
  static const List<_ReferenceStyleSpec> _referenceStyleSpecs = [
    _ReferenceStyleSpec(
      category: 'provincialBoundaries',
      sourceId: 'suelosar-reference-province-source',
      layerId: 'suelosar-reference-province-lines',
      color: Color(0xB0AEB4AC),
      width: 0.9,
    ),
    _ReferenceStyleSpec(
      category: 'majorRivers',
      sourceId: 'suelosar-reference-rivers-source',
      layerId: 'suelosar-reference-rivers-casing',
      color: Color(0xB8F7FBFC),
      width: 3,
    ),
    _ReferenceStyleSpec(
      category: 'majorRivers',
      sourceId: 'suelosar-reference-rivers-source',
      layerId: 'suelosar-reference-rivers',
      color: Color(0xE26BA9CC),
      width: 1.55,
    ),
    _ReferenceStyleSpec(
      category: 'nationalRoads',
      sourceId: 'suelosar-reference-national-roads-source',
      layerId: 'suelosar-reference-national-roads-casing',
      color: Color(0xE8FFF9F5),
      width: 3.4,
    ),
    _ReferenceStyleSpec(
      category: 'nationalRoads',
      sourceId: 'suelosar-reference-national-roads-source',
      layerId: 'suelosar-reference-national-roads',
      color: Color(0xE5BD5738),
      width: 1.65,
    ),
    _ReferenceStyleSpec(
      category: 'provincialRoads',
      sourceId: 'suelosar-reference-provincial-roads-source',
      layerId: 'suelosar-reference-provincial-roads-casing',
      color: Color(0xD8FFF9F5),
      width: 2.65,
      fadeStart: 8.2,
      fadeEnd: 9.5,
    ),
    _ReferenceStyleSpec(
      category: 'provincialRoads',
      sourceId: 'suelosar-reference-provincial-roads-source',
      layerId: 'suelosar-reference-provincial-roads',
      color: Color(0xD2D77A59),
      width: 1.15,
      fadeStart: 8.2,
      fadeEnd: 9.5,
    ),
  ];
  static const String _transparentStyle = '''
{"version":8,"sources":{},"layers":[{"id":"suelosar-transparent","type":"background","paint":{"background-color":"rgba(250,250,248,0)"}}]}
''';

  final Completer<void> _styleReady = Completer<void>();
  final Map<String, ml.FillStyleLayer> _fillLayers = {};
  final Map<String, ml.LineStyleLayer> _outlineLayersBySource = {};
  final Map<String, ml.FillStyleLayer> _selectionLayersBySource = {};
  final Map<String, ml.LineStyleLayer> _selectionOutlineLayersBySource = {};
  final Map<String, _ProvinceHighlight> _provinceHighlights = {};
  final Map<String, ml.LineStyleLayer> _referenceLayers = {};
  final Map<String, PmTilesArchive> _archives = {};
  final SerialAsyncQueue _sourceInstallQueue = SerialAsyncQueue();
  final ValueNotifier<int> _cameraRevision = ValueNotifier(0);
  late final LatestValueAsyncPump<MapLibreMeasurementData>
  _measurementUpdatePump = LatestValueAsyncPump(_applyMeasurementData);
  late final LatestValueAsyncPump<MapLibreProvinceHighlightData>
  _provinceHighlightUpdatePump = LatestValueAsyncPump(
    _applyProvinceHighlightData,
  );

  ml.MapController? _controller;
  ml.StyleController? _style;
  HttpServer? _tileServer;
  List<GisNativeMapSource> _sources = const [];
  List<MapLibreReferenceCity> _referenceCities = const [];
  double _minZoom = 0;
  double _maxZoom = 24;
  Size _size = Size.zero;
  Color _normalFill = const Color(0xFF527036);
  Color _normalBorder = const Color(0xFF527036);
  Color _selectedFill = const Color(0xFF839C52);
  Color _selectedBorder = const Color(0xFF839C52);
  GisFeature? _selectedFeature;
  String? _selectedSourceId;
  bool _soilVisible = true;
  bool _referenceVisible = true;
  bool _referenceLoaded = false;
  Color _surfaceColor = const Color(0xFFFAFAF8);
  double? _lastReferenceZoom;
  bool _moveIsGesture = false;
  bool _gesturesEnabled = true;
  bool _annotationGesturesEnabled = false;
  bool _readySent = false;
  bool _disposed = false;
  SoilMapTapCallback? _onTap;
  SoilMapReadyCallback? _onReady;
  SoilMapPositionChangedCallback? _onPositionChanged;
  List<SoilMapMarkerPin> _personalMarkers = const [];
  ValueChanged<String>? _onMarkerTap;
  LatLng? _currentLocation;
  double? _currentLocationAccuracyMeters;
  bool _showAccuracyCircle = false;
  List<LatLng> _distanceMeasurementPoints = const [];
  List<LatLng> _areaMeasurementPoints = const [];
  Color _measurementColor = Colors.blue;
  List<SoilMapMeasurementMarker> _measurementMarkers = const [];
  List<SavedMeasurement> _savedMeasurements = const [];
  String? _highlightedMeasurementId;
  String? _hoveredMeasurementId;
  ValueChanged<String?>? _onSavedMeasurementHoverChanged;
  GlobalKey? _mapStateKey;
  MapLibreMeasurementData? _lastMeasurementData;
  int _measurementSnapshotVersion = 0;
  int _provinceHighlightSnapshotVersion = 0;
  String? _lastProvinceHighlightData;
  Future<void>? _measurementSetupFuture;
  final Set<String> _measurementStyleLayerIds = {};
  final Set<String> _registeredMeasurementImages = {};
  final Set<String> _provinceHighlightLayerIds = {};
  Future<void>? _provinceHighlightSyncFuture;
  bool _provinceHighlightSyncRequested = false;
  final Set<String> _annotationStyleLayerIds = {};
  final Set<String> _registeredAnnotationImages = {};
  Future<void>? _cityLabelImageFuture;
  String? _lastCityAnnotationData;
  String? _lastPersonalMarkerData;
  String? _lastLocationData;
  bool _nativeAnnotationLayersReady = false;
  int _renderingResumeCount = 0;
  Future<void>? _nativeAnnotationSyncFuture;
  bool _nativeAnnotationSyncRequested = false;
  Stopwatch? _referenceBasemapClock;
  bool _reportedFirstLocalitySprite = false;
  bool _reportedFirstAdministrativeSprite = false;

  @override
  bool get rendersSoilPolygonsInternally => true;

  @visibleForTesting
  bool get debugNativeAnnotationLayersReady => _nativeAnnotationLayersReady;

  @visibleForTesting
  int get debugRenderingResumeCount => _renderingResumeCount;

  @visibleForTesting
  Set<String> get debugNativeAnnotationLayerIds =>
      Set.unmodifiable(_annotationStyleLayerIds);

  @visibleForTesting
  Set<String> get debugAdministrativeBoundaryLayerIds => Set.unmodifiable(
    _administrativeBoundaryLayerIds.values.where(
      (id) => _style?.layers[id] != null,
    ),
  );

  @visibleForTesting
  int get debugCityAnnotationCount => _referenceCities.length;

  @visibleForTesting
  String? get debugCurrentLocationData => _lastLocationData;

  @visibleForTesting
  String? get debugActiveMeasurementData => _lastMeasurementData?.active;

  @visibleForTesting
  String? get debugSavedMeasurementData => _lastMeasurementData?.saved;

  @visibleForTesting
  String? get debugProvinceHighlightData => _lastProvinceHighlightData;

  @visibleForTesting
  int get debugMeasurementSnapshotVersion =>
      _lastMeasurementData?.snapshotVersion ?? -1;

  @visibleForTesting
  Set<String> get debugProvinceHighlightLayerIds =>
      Set.unmodifiable(_provinceHighlightLayerIds);

  @visibleForTesting
  Set<String> get debugMeasurementLayerIds =>
      Set.unmodifiable(_measurementStyleLayerIds);

  @visibleForTesting
  List<String> get debugMeasurementLayerOrder => List.unmodifiable(
    _style?.layers
            .where((layer) => _measurementStyleLayerIds.contains(layer.id))
            .map((layer) => layer.id) ??
        const <String>[],
  );

  @visibleForTesting
  Set<String> get debugSelectionLayerIds => Set.unmodifiable(
    _selectionLayersBySource.values.map((layer) => layer.id),
  );

  @visibleForTesting
  Set<String> get debugSoilOutlineLayerIds =>
      Set.unmodifiable(_outlineLayersBySource.values.map((layer) => layer.id));

  @visibleForTesting
  Set<String> get debugSelectionOutlineLayerIds => Set.unmodifiable(
    _selectionOutlineLayersBySource.values.map((layer) => layer.id),
  );

  @visibleForTesting
  Map<String, Object?> get debugSelectionFilters => Map.unmodifiable({
    for (final entry in _selectionLayersBySource.entries)
      entry.value.id: entry.value.filter?.toJson(),
  });

  @visibleForTesting
  Map<String, (String, String?)> get debugSelectionLayerBindings =>
      Map.unmodifiable({
        for (final entry in _selectionLayersBySource.entries)
          entry.value.id: (entry.value.sourceId, entry.value.sourceLayerId),
      });

  @visibleForTesting
  Set<String> get debugVisibleSelectionLayerIds => Set.unmodifiable(
    _selectionLayersBySource.values
        .where((layer) => layer.visible)
        .map((layer) => layer.id),
  );

  @visibleForTesting
  Future<void> debugSyncMeasurements() => _syncMeasurementSources();

  @visibleForTesting
  Future<void> debugSyncProvinceHighlights() => _syncProvinceHighlights();

  @visibleForTesting
  String? get debugPersonalMarkerData => _lastPersonalMarkerData;

  @visibleForTesting
  Future<void> debugSyncNativeAnnotations() => _syncNativeAnnotationSources();

  @visibleForTesting
  Future<bool> debugDispatchPersonalMarkerTap(Offset position) =>
      _dispatchPersonalMarkerTap(position);

  @visibleForTesting
  Future<Set<String>> debugRenderedPersonalMarkerIdsAt(Offset position) =>
      _queryPersonalMarkerIds(position);

  @visibleForTesting
  Future<Set<String>> debugRenderedPersonalMarkerIdsInViewport() async {
    final controller = _controller;
    if (controller == null) return const {};
    final rendered = await controller.featuresInRect(
      Rect.fromLTWH(0, 0, _size.width, _size.height),
      layerIds: [_personalMarkerCircleLayerId, _personalMarkerLayerId],
    );
    return rendered
        .map((feature) => feature.properties['markerId'] ?? feature.id)
        .whereType<String>()
        .toSet();
  }

  @visibleForTesting
  void debugSetAnnotationGesturesEnabled(bool enabled) {
    _annotationGesturesEnabled = enabled;
  }

  @override
  Listenable get cameraChanges => _cameraRevision;

  @override
  SoilMapCameraState get camera {
    final controller = _controller;
    if (controller == null) {
      return const SoilMapCameraState(
        center: LatLng(0, 0),
        zoom: 0,
        rotation: 0,
      );
    }
    final current = controller.getCamera();
    return SoilMapCameraState(
      center: LatLng(current.center.lat, current.center.lon),
      zoom: current.zoom + 1,
      rotation: current.bearing,
      visibleBounds: _visibleBounds(controller),
    );
  }

  @visibleForTesting
  bool get debugReferenceBasemapLoaded => _referenceLoaded;

  @visibleForTesting
  bool get debugReferenceLabelSpritesReady {
    if (_referenceCities.isEmpty || _cityLabelImageFuture != null) return false;
    for (final city in _referenceCities) {
      final variants = city.provinceId == 'buenos_aires'
          ? const [false, true]
          : const [false];
      for (final enhanced in variants) {
        final imageId = city.isAdministrative
            ? MapLibreGeographicAnnotationData.administrativeLabelImageId(
                city.id,
                enhancedForSoilPolygons: enhanced,
              )
            : MapLibreGeographicAnnotationData.cityLabelImageId(
                city.id,
                enhancedForSoilPolygons: enhanced,
              );
        if (!_registeredAnnotationImages.contains(imageId)) return false;
      }
    }
    return true;
  }

  @visibleForTesting
  List<double?> get debugAdministrativeLabelOpacities => [
    for (final id in _departmentLabelLayerIds)
      _literalLayerOpacity(_style?.layers[id]),
  ];

  @visibleForTesting
  List<bool?> get debugAdministrativeBoundaryVisibility => [
    for (final id in _administrativeBoundaryLayerIds.values)
      _style?.layers[id]?.visible,
  ];

  @visibleForTesting
  Future<int> debugRenderedReferenceSymbolCount() async {
    final controller = _controller;
    final size = _size;
    if (controller == null || size.width <= 0 || size.height <= 0) return 0;
    final rendered = await controller.featuresInRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      layerIds: [
        _cityLabelLayerId,
        _citySecondaryLabelLayerId,
        ..._departmentLabelLayerIds,
      ],
    );
    return rendered.length;
  }

  double? _literalLayerOpacity(ml.StyleLayer? layer) {
    if (layer is! ml.SymbolStyleLayer) return null;
    final opacity = layer.iconOpacity;
    return opacity is ml.Literal<num> ? opacity.value.toDouble() : null;
  }

  SoilMapVisibleBounds? _visibleBounds(ml.MapController controller) {
    final size = _size;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return null;
    }

    // Use the extent captured by LayoutBuilder and the native camera
    // projection without reading a RenderBox during the build phase.
    final corners = controller.toLngLats([
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]);
    return SoilMapVisibleBounds.fromCorners([
      for (final point in corners) LatLng(point.lat, point.lon),
    ]);
  }

  @override
  Widget buildMapSurface({
    Key? key,
    required LatLng initialCenter,
    required double initialZoom,
    required double minZoom,
    required double maxZoom,
    required Color backgroundColor,
    required bool gesturesEnabled,
    required bool annotationGesturesEnabled,
    required SoilMapReadyCallback onReady,
    required SoilMapPositionChangedCallback onPositionChanged,
    SoilMapTapCallback? onTap,
    required List<Widget> children,
    List<Widget> mapFrameChildren = const [],
  }) {
    _minZoom = minZoom;
    _maxZoom = maxZoom;
    _surfaceColor = backgroundColor;
    _onReady = onReady;
    _onPositionChanged = onPositionChanged;
    _onTap = onTap;
    _gesturesEnabled = gesturesEnabled;
    _annotationGesturesEnabled = annotationGesturesEnabled;
    _mapStateKey = key is GlobalKey ? key : null;

    final annotations = children.where((child) {
      final candidate = child is Positioned ? child.child : child;
      return candidate is! OfflineReferenceMapLayer;
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        final nextSize = constraints.biggest;
        if (_size != nextSize) {
          _size = nextSize;
        }
        final center = ml.Geographic(
          lon: initialCenter.longitude,
          lat: initialCenter.latitude,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            MouseRegion(
              onHover: (event) =>
                  _updateHoveredSavedMeasurement(event.localPosition),
              onExit: (_) => _onSavedMeasurementHoverChanged?.call(null),
              child: ml.MapLibreMap(
                key: key,
                options: ml.MapOptions(
                  style: const ml.MapStyle.json(_transparentStyle),
                  initCamera: ml.InitialCamera.position(
                    center: center,
                    zoom: initialZoom - 1,
                    bearing: 0,
                    pitch: 0,
                  ),
                  minZoom: math.max(0, minZoom - 1).toDouble(),
                  maxZoom: math.min(24, maxZoom - 1).toDouble(),
                  gestures: gesturesEnabled
                      ? const ml.MapGestures.all(pitch: false)
                      : const ml.MapGestures.none(),
                ),
                onMapCreated: _handleMapCreated,
                onStyleLoaded: _handleStyleLoaded,
                onEvent: _handleMapEvent,
                children: [
                  Positioned.fill(
                    child: _MapFrameProjectionRevisionBridge(
                      revision: _cameraRevision,
                    ),
                  ),
                  if (_measurementMarkers.isNotEmpty)
                    ml.WidgetLayer(
                      allowInteraction: true,
                      markers: [
                        for (final marker in _measurementMarkers)
                          ml.Marker(
                            point: ml.Geographic(
                              lon: marker.point.longitude,
                              lat: marker.point.latitude,
                            ),
                            size: marker.size,
                            alignment: marker.alignment,
                            child: marker.child,
                          ),
                      ],
                    ),
                  ...mapFrameChildren,
                ],
              ),
            ),
            if (annotations.isNotEmpty)
              AnimatedBuilder(
                animation: _cameraRevision,
                builder: (context, _) => Stack(
                  fit: StackFit.expand,
                  children: annotations.toList(growable: false),
                ),
              ),
          ],
        );
      },
    );
  }

  void _handleMapCreated(ml.MapController controller) {
    if (_disposed) return;
    _controller = controller;
  }

  void _handleStyleLoaded(ml.StyleController style) {
    if (_disposed) return;
    final styleChanged = _style != null && !identical(_style, style);
    _style = style;
    if (styleChanged) {
      _measurementSetupFuture = null;
      _measurementStyleLayerIds.clear();
      _registeredMeasurementImages.clear();
      _provinceHighlightLayerIds.clear();
      _annotationStyleLayerIds.clear();
      _registeredAnnotationImages.clear();
      _cityLabelImageFuture = null;
      _lastCityAnnotationData = null;
      _lastPersonalMarkerData = null;
      _lastLocationData = null;
      _nativeAnnotationLayersReady = false;
      _lastMeasurementData = null;
      _lastProvinceHighlightData = null;
      unawaited(_syncMeasurementSources());
      unawaited(_syncProvinceHighlights());
      unawaited(_syncNativeAnnotationSources());
    }
    if (!_styleReady.isCompleted) _styleReady.complete();
    _notifyReady();
  }

  void _handleMapEvent(ml.MapEvent event) {
    if (_disposed) return;
    if (event is ml.MapEventRenderingChanged && !event.paused) {
      _renderingResumeCount++;
      _lastReferenceZoom = null;
      _updateReferenceLayerVisibility(camera.zoom);
      unawaited(_syncNativeAnnotationSources());
      unawaited(_syncProvinceHighlights());
      unawaited(_syncMeasurementSources());
    } else if (event is ml.MapEventStartMoveCamera) {
      _moveIsGesture = event.reason == ml.CameraChangeReason.apiGesture;
    } else if (event is ml.MapEventMoveCamera) {
      _updateReferenceLayerVisibility(event.camera.zoom + 1);
      _onPositionChanged?.call(camera, hasGesture: _moveIsGesture);
    } else if (event is ml.MapEventCameraIdle) {
      _moveIsGesture = false;
      final controller = _controller;
      if (controller != null && _referenceLoaded) {
        // Reconcile against the settled native camera as the final move event
        // can precede an asynchronous camera animation's actual end state.
        _lastReferenceZoom = null;
        _updateReferenceLayerVisibility(controller.getCamera().zoom + 1);
      }
    } else if (event is ml.MapEventClick) {
      unawaited(_routeMapClick(event));
    }
  }

  Future<void> _routeMapClick(ml.MapEventClick event) async {
    if (_disposed || _measurementVertexAt(event.screenPoint) != null) return;
    if (await _dispatchPersonalMarkerTap(event.screenPoint)) return;
    if (_disposed) return;
    _onTap?.call(
      SoilMapTapDetails(
        screenOffset: event.screenPoint,
        point: LatLng(event.point.lat, event.point.lon),
      ),
    );
  }

  Future<bool> _dispatchPersonalMarkerTap(Offset position) async {
    if (_disposed || _annotationGesturesEnabled || _personalMarkers.isEmpty) {
      return false;
    }
    final controller = _controller;
    if (controller == null) return false;
    try {
      final hitIds = await _queryPersonalMarkerIds(position);
      // The old Flutter MarkerLayer put later entries above earlier ones.
      final marker = _personalMarkers.reversed
          .where((candidate) => hitIds.contains(candidate.id))
          .firstOrNull;
      if (marker == null) return false;
      _onMarkerTap?.call(marker.id);
      return true;
    } catch (error) {
      debugPrint('MapLibre personal-marker hit test failed: $error');
      return false;
    }
  }

  Future<Set<String>> _queryPersonalMarkerIds(Offset position) async {
    final controller = _controller;
    if (controller == null) return const {};
    var rendered = await controller.featuresAtPoint(
      position,
      layerIds: [_personalMarkerCircleLayerId, _personalMarkerLayerId],
    );
    if (rendered.isEmpty) {
      rendered = await controller.featuresInRect(
        Rect.fromCenter(center: position, width: 8, height: 8),
        layerIds: [_personalMarkerCircleLayerId, _personalMarkerLayerId],
      );
    }
    return rendered
        .map((feature) => feature.properties['markerId'] ?? feature.id)
        .whereType<String>()
        .toSet();
  }

  int? _measurementVertexAt(Offset point) {
    final controller = _controller;
    if (controller == null) return null;
    final activePoints = _areaMeasurementPoints.isNotEmpty
        ? _areaMeasurementPoints
        : _distanceMeasurementPoints;
    final vertexCount = math.min(
      _measurementMarkers.length,
      activePoints.length,
    );
    for (var index = vertexCount - 1; index >= 0; index--) {
      final marker = _measurementMarkers[index];
      final anchor = controller.toScreenLocation(
        ml.Geographic(lon: marker.point.longitude, lat: marker.point.latitude),
      );
      final rect = Rect.fromLTWH(
        anchor.dx - marker.size.width / 2 * (marker.alignment.x + 1),
        anchor.dy - marker.size.height / 2 * (marker.alignment.y + 1),
        marker.size.width,
        marker.size.height,
      );
      if (rect.contains(point)) return index;
    }
    return null;
  }

  void _notifyReady() {
    if (_disposed || _readySent || _controller == null || _style == null) {
      return;
    }
    _readySent = true;
    _updateReferenceLayerVisibility(_controller!.getCamera().zoom + 1);
    unawaited(_syncMeasurementSources());
    unawaited(_syncNativeAnnotationSources());
    _onReady?.call();
  }

  @override
  void move(LatLng center, double zoom) {
    _controller?.moveCamera(
      center: ml.Geographic(lon: center.longitude, lat: center.latitude),
      zoom: (zoom - 1).clamp(_minZoom - 1, _maxZoom - 1).toDouble(),
    );
  }

  @override
  void zoomAtScreenPoint(Offset screenPoint, double scrollDeltaY) {
    if (scrollDeltaY == 0 || !scrollDeltaY.isFinite || !_gesturesEnabled) {
      return;
    }
    final mapState = _mapStateKey?.currentState;
    if (mapState is! ml.MapLibreMapState) return;
    final currentZoom = camera.zoom;
    final targetZoom = (currentZoom - scrollDeltaY / 450)
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    final delta = targetZoom - currentZoom;
    if (delta != 0) mapState.gestureCamera?.zoomBy(delta, screenPoint);
  }

  @override
  void rotate(double degrees) {
    _controller?.moveCamera(bearing: degrees);
  }

  @override
  SoilMapCameraState fitBounds(
    List<LatLng> points, {
    EdgeInsets padding = EdgeInsets.zero,
    double? maxZoom,
  }) {
    if (points.isEmpty) return camera;
    var west = points.first.longitude;
    var east = west;
    var south = points.first.latitude;
    var north = south;
    for (final point in points.skip(1)) {
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
    }
    final spanX = (_mercatorX(east) - _mercatorX(west)).abs().clamp(1e-12, 1.0);
    final spanY = (_mercatorY(south) - _mercatorY(north)).abs().clamp(
      1e-12,
      1.0,
    );
    final availableWidth = math.max(1, _size.width - padding.horizontal);
    final availableHeight = math.max(1, _size.height - padding.vertical);
    final zoom = math
        .min(
          math.log(availableWidth / (256 * spanX)) / math.ln2,
          math.log(availableHeight / (256 * spanY)) / math.ln2,
        )
        .clamp(_minZoom, math.min(_maxZoom, maxZoom ?? _maxZoom));
    final center = LatLng(
      _inverseMercatorY((_mercatorY(south) + _mercatorY(north)) / 2),
      (west + east) / 2,
    );
    return SoilMapCameraState(
      center: center,
      zoom: zoom.toDouble(),
      rotation: 0,
    );
  }

  @override
  Offset? latLngToScreenOffset(LatLng point) {
    final controller = _controller;
    if (controller == null) return null;
    final offset = controller.toScreenLocation(
      ml.Geographic(lon: point.longitude, lat: point.latitude),
    );
    return offset;
  }

  @override
  LatLng? screenOffsetToLatLng(Offset offset) {
    final controller = _controller;
    if (controller == null) return null;
    final point = controller.toLngLat(offset);
    return LatLng(point.lat, point.lon);
  }

  @override
  Future<void> loadSoilPolygonsLayer({
    required GisArchiveInfo archiveInfo,
    required String layerName,
    required Color normalFillColor,
    required Color selectedFillColor,
    required List<GisNativeMapSource> sources,
  }) async {
    _normalFill = normalFillColor.withValues(
      alpha: soilPolygonFillOpacityFor(defaultTargetPlatform),
    );
    _normalBorder = normalFillColor;
    _selectedFill = selectedFillColor.withValues(alpha: 0.55);
    _selectedBorder = selectedFillColor;
    _sources = List.unmodifiable(sources);
    _lastReferenceZoom = null;
    await _styleReady.future;
    if (_disposed) return;
    await _installSoilSources();
  }

  Future<void> _installSoilSources() async {
    await _sourceInstallQueue.run(_installSoilSourcesNow);
    await _syncMeasurementSources();
  }

  Future<void> _installSoilSourcesNow() async {
    final style = _style;
    if (style == null) return;
    final server = _sources.isEmpty ? null : await _ensureTileServer();
    final activeIds = _sources.map((source) => source.id).toSet();
    for (final id
        in _archives.keys.where((id) => !activeIds.contains(id)).toList()) {
      await style.layers.remove('$id$_fillSuffix');
      _fillLayers.remove('$id$_fillSuffix');
      final outlineLayer = _outlineLayersBySource.remove(id);
      if (outlineLayer != null) {
        await style.layers.remove(outlineLayer.id);
      }
      final selectionLayer = _selectionLayersBySource.remove(id);
      if (selectionLayer != null) {
        await style.layers.remove(selectionLayer.id);
      }
      final selectionOutlineLayer = _selectionOutlineLayersBySource.remove(id);
      if (selectionOutlineLayer != null) {
        await style.layers.remove(selectionOutlineLayer.id);
      }
      if (_selectedSourceId == id) _selectedSourceId = null;
      await style.sources.remove(id);
      await _archives.remove(id)?.close();
    }
    for (final source in _sources) {
      if (style.sources[source.id] == null) {
        final archive = await PmTilesArchive.fromFile(File(source.archivePath));
        _archives[source.id] = archive;
        await style.sources.add(
          ml.VectorSource.tiles(
            id: source.id,
            tiles: [
              'http://127.0.0.1:${server!.port}/'
                  '${source.id}/{z}/{x}/{y}.pbf',
            ],
            minZoom: math.max(0, archive.minZoom - 1).toDouble(),
            maxZoom: math.max(0, archive.maxZoom - 1).toDouble(),
          ),
        );
      }
      final fillId = '${source.id}$_fillSuffix';
      if (_fillLayers[fillId] == null) {
        final fill = ml.FillStyleLayer(
          id: fillId,
          sourceId: source.id,
          sourceLayerId: source.layerName,
          color: ml.Literal(_normalFill),
          opacity: const ml.Literal(1),
          outlineColor: ml.Literal(soilPolygonFillOutlineColor()),
          visible: _soilVisible,
        );
        await style.layers.add(fill);
        _fillLayers[fillId] = fill;
      }
    }
    final normalOutlineWidth = soilPolygonOutlineWidthFor(
      defaultTargetPlatform,
    );
    if (normalOutlineWidth != null) {
      for (final source in _sources) {
        if (_outlineLayersBySource.containsKey(source.id)) continue;
        final outline = ml.LineStyleLayer(
          id: '${source.id}$_outlineSuffix',
          sourceId: source.id,
          sourceLayerId: source.layerName,
          color: ml.Literal(_normalBorder),
          width: ml.Literal(normalOutlineWidth),
          cap: const ml.Literal(ml.LineCap.round),
          join: const ml.Literal(ml.LineJoin.round),
          visible: _soilVisible,
        );
        await style.layers.add(outline);
        _outlineLayersBySource[source.id] = outline;
      }
    }
    for (final source in _sources) {
      if (_selectionLayersBySource.containsKey(source.id)) continue;
      final selected = ml.FillStyleLayer(
        id: '${source.id}$_selectionSuffix',
        sourceId: source.id,
        sourceLayerId: source.layerName,
        filter: _noFeatureFilter,
        color: ml.Literal(_selectedFill),
        opacity: const ml.Literal(1),
        outlineColor: ml.Literal(soilPolygonFillOutlineColor()),
        visible: false,
      );
      await style.layers.add(selected);
      _selectionLayersBySource[source.id] = selected;
    }
    final selectedOutlineWidth = selectedSoilPolygonOutlineWidthFor(
      defaultTargetPlatform,
    );
    if (selectedOutlineWidth != null) {
      for (final source in _sources) {
        if (_selectionOutlineLayersBySource.containsKey(source.id)) continue;
        final selectedOutline = ml.LineStyleLayer(
          id: '${source.id}$_selectionOutlineSuffix',
          sourceId: source.id,
          sourceLayerId: source.layerName,
          filter: _noFeatureFilter,
          color: ml.Literal(_selectedBorder),
          width: ml.Literal(selectedOutlineWidth),
          cap: const ml.Literal(ml.LineCap.round),
          join: const ml.Literal(ml.LineJoin.round),
          visible: false,
        );
        await style.layers.add(selectedOutline);
        _selectionOutlineLayersBySource[source.id] = selectedOutline;
      }
    }
    await _syncSelectedFeature();
    _moveAdministrativeBoundaryLayersToTop();
    await _syncNativeAnnotationSourcesNow();
    _moveNativeAnnotationLayersToTop();
    _moveMeasurementLayersToTop();
    _lastReferenceZoom = null;
    _updateReferenceLayerVisibility(camera.zoom);
  }

  Future<void> _syncNativeAnnotationSources() async {
    if (_disposed) return;
    _nativeAnnotationSyncRequested = true;
    final pending = _nativeAnnotationSyncFuture;
    if (pending != null) return pending;
    final sync = () async {
      await _styleReady.future;
      while (_nativeAnnotationSyncRequested && !_disposed) {
        _nativeAnnotationSyncRequested = false;
        await _sourceInstallQueue.run(_syncNativeAnnotationSourcesNow);
      }
    }();
    _nativeAnnotationSyncFuture = sync;
    try {
      await sync;
    } finally {
      if (identical(_nativeAnnotationSyncFuture, sync)) {
        _nativeAnnotationSyncFuture = null;
      }
      if (_nativeAnnotationSyncRequested && !_disposed) {
        unawaited(_syncNativeAnnotationSources());
      }
    }
  }

  Future<void> _syncNativeAnnotationSourcesNow() async {
    if (_disposed) return;
    final style = _style;
    if (style == null) return;

    await _ensureNativeAnnotationImages(style);
    if (_disposed || !identical(_style, style)) return;
    final missingCitySource = style.sources[_cityAnnotationSourceId] == null;
    final missingPersonalMarkerSource =
        style.sources[_personalMarkerSourceId] == null;
    final missingLocationSource = style.sources[_locationSourceId] == null;
    for (final entry in [
      MapEntry(_cityAnnotationSourceId, _emptyFeatureCollection),
      MapEntry(_personalMarkerSourceId, _emptyFeatureCollection),
      MapEntry(_locationSourceId, _emptyFeatureCollection),
    ]) {
      if (style.sources[entry.key] == null) {
        await style.sources.add(
          ml.GeoJsonSource.data(id: entry.key, data: entry.value),
        );
      }
    }

    await _ensureNativeAnnotationLayers(style);
    if (_disposed || !identical(_style, style)) return;
    _updateAdministrativeLabelOpacity(camera.zoom);

    final enhancedAdministrativeProvinceIds = _soilVisible
        ? _sources.map((source) => source.coverageId).toSet()
        : const <String>{};
    final cityData = MapLibreGeographicAnnotationData.cities(
      _referenceCities,
      enhancedAdministrativeProvinceIds: enhancedAdministrativeProvinceIds,
    );
    if (missingCitySource || _lastCityAnnotationData != cityData) {
      await style.sources.updateGeoJsonData(_cityAnnotationSourceId, cityData);
      if (_disposed || !identical(_style, style)) return;
      _lastCityAnnotationData = cityData;
    }
    _scheduleCityLabelImageRegistration(style);
    final personalData = MapLibreGeographicAnnotationData.personalMarkers(
      _personalMarkers,
    );
    if (missingPersonalMarkerSource ||
        _lastPersonalMarkerData != personalData) {
      await style.sources.updateGeoJsonData(
        _personalMarkerSourceId,
        personalData,
      );
      if (_disposed || !identical(_style, style)) return;
      _lastPersonalMarkerData = personalData;
    }
    final hasAccuracy =
        _showAccuracyCircle &&
        SettingsService.instance.showGpsAccuracyCircle &&
        (_currentLocationAccuracyMeters ?? 0) > 0 &&
        (_currentLocationAccuracyMeters ?? 0).isFinite;
    final locationData = MapLibreGeographicAnnotationData.currentLocation(
      point: _currentLocation,
      accuracyMeters: hasAccuracy ? _currentLocationAccuracyMeters! : 0,
      hasAccuracy: hasAccuracy,
    );
    if (missingLocationSource || _lastLocationData != locationData) {
      await style.sources.updateGeoJsonData(_locationSourceId, locationData);
      if (_disposed || !identical(_style, style)) return;
      _lastLocationData = locationData;
    }
    _moveNativeAnnotationLayersToTop();
    _moveMeasurementLayersToTop();
  }

  Future<void> _ensureNativeAnnotationImages(ml.StyleController style) async {
    if (_registeredAnnotationImages.add(_locationImageId)) {
      await style.addImageFromCanvas(
        id: _locationImageId,
        width: 28,
        height: 28,
        painter: (canvas) {
          final center = const Offset(14, 14);
          final markerPath = ui.Path()
            ..addOval(Rect.fromCircle(center: center, radius: 11));
          canvas.drawShadow(
            markerPath,
            Colors.black.withValues(alpha: 0.28),
            8,
            true,
          );
          canvas.drawCircle(center, 11, Paint()..color = _surfaceColor);
          canvas.drawCircle(
            center,
            8,
            Paint()..color = const Color(0xFF1976D2),
          );
        },
      );
    }

    for (final marker in _personalMarkers) {
      final imageId = MapLibreGeographicAnnotationData.personalMarkerImageId(
        marker.categoryId,
      );
      if (!_registeredAnnotationImages.add(imageId)) continue;
      await style.addImageFromCanvas(
        id: imageId,
        width: 44,
        height: 44,
        painter: (canvas) {
          final center = const Offset(22, 22);
          final iconData = marker.icon;
          final painter = TextPainter(
            text: TextSpan(
              text: String.fromCharCode(iconData.codePoint),
              style: TextStyle(
                color: const Color(0xFFD11313),
                fontFamily: iconData.fontFamily,
                package: iconData.fontPackage,
                fontSize: 22,
              ),
            ),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
          )..layout();
          painter.paint(
            canvas,
            center - Offset(painter.width / 2, painter.height / 2),
          );
        },
      );
    }
  }

  void _scheduleCityLabelImageRegistration(ml.StyleController style) {
    if (_referenceCities.isEmpty || _cityLabelImageFuture != null) return;
    final registration = _registerCityLabelImages(style);
    _cityLabelImageFuture = registration;
    unawaited(
      registration
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint(
              'MapLibre geographic label image registration failed: $error',
            );
          })
          .whenComplete(() {
            if (identical(_cityLabelImageFuture, registration)) {
              _cityLabelImageFuture = null;
            }
          }),
    );
  }

  Future<void> _registerCityLabelImages(ml.StyleController style) async {
    final zoom = camera.zoom;
    final enhancedAdministrativeProvinceIds = _soilVisible
        ? _sources.map((source) => source.coverageId).toSet()
        : const <String>{};
    final requests = <(MapLibreReferenceCity, bool, String, int)>[];
    final prioritizedCities =
        MapLibreReferenceBasemapData.prioritizeLabelRegistration(
          _referenceCities,
          zoom: zoom,
        );
    for (var cityIndex = 0; cityIndex < prioritizedCities.length; cityIndex++) {
      final city = prioritizedCities[cityIndex];
      final variants = city.provinceId == 'buenos_aires'
          ? const [false, true]
          : const [false];
      for (final enhanced in variants) {
        final imageId = city.isAdministrative
            ? MapLibreGeographicAnnotationData.administrativeLabelImageId(
                city.id,
                enhancedForSoilPolygons: enhanced,
              )
            : MapLibreGeographicAnnotationData.cityLabelImageId(
                city.id,
                enhancedForSoilPolygons: enhanced,
              );
        final activeVariant =
            enhanced ==
            (city.provinceId == 'buenos_aires' &&
                enhancedAdministrativeProvinceIds.contains('buenos_aires'));
        requests.add((
          city,
          enhanced,
          imageId,
          cityIndex * 2 + (activeVariant ? 0 : 1),
        ));
      }
    }
    requests.sort((first, second) => first.$4.compareTo(second.$4));

    const batchSize = 12;
    for (var start = 0; start < requests.length; start += batchSize) {
      if (_disposed || !identical(_style, style)) return;
      final end = math.min(start + batchSize, requests.length);
      await Future.wait<void>([
        for (final (city, enhanced, imageId, _) in requests.sublist(start, end))
          _registerCityLabelImage(style, city, enhanced, imageId),
      ]);
    }
  }

  Future<void> _registerCityLabelImage(
    ml.StyleController style,
    MapLibreReferenceCity city,
    bool enhanced,
    String imageId,
  ) async {
    if (_disposed ||
        !identical(_style, style) ||
        !_registeredAnnotationImages.add(imageId)) {
      return;
    }
    final isAdministrative = city.isAdministrative;
    final label = isAdministrative ? city.name.toUpperCase() : city.name;
    final enhancedForSoilPolygons =
        enhanced &&
        _sources.any((source) => source.coverageId == city.provinceId);
    final textStyle = TextStyle(
      color: isAdministrative
          ? enhancedForSoilPolygons
                ? const Color(0xFF20271F)
                : const Color(0xFF4B5148)
          : enhancedForSoilPolygons
          ? const Color(0xFF20271F)
          : const Color(0xFF29312C),
      fontSize: isAdministrative
          ? 10.5
          : city.isPrimary
          ? 16
          : 14.5,
      fontWeight: city.isPrimary ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: isAdministrative ? 0.8 : 0,
      height: isAdministrative ? 1 : 1.05,
    );
    final fillPainter = TextPainter(
      text: TextSpan(text: label, style: textStyle),
      textAlign: isAdministrative ? TextAlign.center : TextAlign.start,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final haloWidth = isAdministrative
        ? enhancedForSoilPolygons
              ? 3.8
              : 3.4
        : enhancedForSoilPolygons
        ? 3.8
        : city.isPrimary
        ? 5.0
        : 4.2;
    final haloColor = enhancedForSoilPolygons
        ? const Color(0xFFF7F7F1)
        : const Color(0xFFFCFCFA);
    final haloPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: textStyle.copyWith(
          color: null,
          foreground: Paint()
            ..color = haloColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = haloWidth
            ..strokeJoin = StrokeJoin.round,
        ),
      ),
      textAlign: isAdministrative ? TextAlign.center : TextAlign.start,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    const haloPadding = 3.0;
    final width = math.max(
      1.0,
      fillPainter.width.ceilToDouble() + haloPadding * 2,
    );
    final height = math.max(
      1.0,
      fillPainter.height.ceilToDouble() + haloPadding * 2,
    );
    final textOffset = Offset(
      haloPadding + (width - haloPadding * 2 - fillPainter.width) / 2,
      haloPadding + (height - haloPadding * 2 - fillPainter.height) / 2,
    );
    try {
      await style.addImageFromCanvas(
        id: imageId,
        width: width,
        height: height,
        painter: (canvas) {
          haloPainter.paint(canvas, textOffset);
          fillPainter.paint(canvas, textOffset);
        },
      );
      final clock = _referenceBasemapClock;
      if (kProfileMode && clock != null) {
        if (city.isAdministrative && !_reportedFirstAdministrativeSprite) {
          _reportedFirstAdministrativeSprite = true;
          debugPrint(
            'GIS_LABEL_TIMING first_district_sprite_ready_ms=${clock.elapsedMilliseconds}',
          );
        } else if (!city.isAdministrative && !_reportedFirstLocalitySprite) {
          _reportedFirstLocalitySprite = true;
          debugPrint(
            'GIS_LABEL_TIMING first_locality_sprite_ready_ms=${clock.elapsedMilliseconds}',
          );
        }
      }
    } catch (_) {
      _registeredAnnotationImages.remove(imageId);
      if (kProfileMode) {
        debugPrint('GIS_LABEL_TIMING sprite_registration_failed=$imageId');
      }
    }
  }

  Future<void> _ensureNativeAnnotationLayers(ml.StyleController style) async {
    if (_nativeAnnotationLayersReady &&
        _annotationStyleLayerIds.every((id) => style.layers[id] != null)) {
      return;
    }
    if (style.layers[_cityDotLayerId] == null) {
      await style.layers.add(
        ml.CircleStyleLayer(
          id: _cityDotLayerId,
          sourceId: _cityAnnotationSourceId,
          filter: ml.Expression.raw([
            '==',
            ['get', 'isPrimary'],
            true,
          ]),
          radius: const ml.Literal(2.7),
          color: const ml.Literal(Color(0xFF303632)),
          opacity: const ml.Literal(1),
          strokeWidth: const ml.Literal(0.2),
          strokeColor: const ml.Literal(Color(0xFF303632)),
          strokeOpacity: const ml.Literal(1),
          visible: _referenceVisible,
        ),
      );
      _annotationStyleLayerIds.add(_cityDotLayerId);
    }
    if (style.layers[_citySecondaryDotLayerId] == null) {
      await style.layers.add(
        ml.CircleStyleLayer(
          id: _citySecondaryDotLayerId,
          sourceId: _cityAnnotationSourceId,
          filter: ml.Expression.raw([
            'all',
            [
              '==',
              ['get', 'isPrimary'],
              false,
            ],
            [
              '==',
              ['get', 'isAdministrative'],
              false,
            ],
          ]),
          radius: const ml.Literal(2.3),
          color: const ml.Literal(Color(0xFF303632)),
          opacity: _citySecondaryVisibilityExpression,
          strokeWidth: const ml.Literal(0.2),
          strokeColor: const ml.Literal(Color(0xFF303632)),
          strokeOpacity: _citySecondaryVisibilityExpression,
          visible: _referenceVisible,
        ),
      );
      _annotationStyleLayerIds.add(_citySecondaryDotLayerId);
    }
    if (style.layers[_cityLabelLayerId] == null) {
      await style.layers.add(
        ml.SymbolStyleLayer(
          id: _cityLabelLayerId,
          sourceId: _cityAnnotationSourceId,
          filter: ml.Expression.raw([
            '==',
            ['get', 'isPrimary'],
            true,
          ]),
          iconImage: ml.Expression.image(
            ml.Expression.get('labelImage').asString(),
          ),
          iconAnchor: const ml.Literal(ml.IconAnchor.left),
          iconOffset: const ml.Literal(Offset(5, 0)),
          iconAllowOverlap: const ml.Literal(false),
          iconIgnorePlacement: const ml.Literal(false),
          iconOptional: const ml.Literal(false),
          iconSize: const ml.Literal(1),
          iconOpacity: _cityBaseOpacityExpression,
          sortKey: ml.Expression.get('sortKey').asNumber(),
          zOrder: const ml.Literal(ml.SymbolZOrder.source),
          visible: _referenceVisible,
        ),
      );
      _annotationStyleLayerIds.add(_cityLabelLayerId);
    }
    if (style.layers[_citySecondaryLabelLayerId] == null) {
      await style.layers.add(
        ml.SymbolStyleLayer(
          id: _citySecondaryLabelLayerId,
          sourceId: _cityAnnotationSourceId,
          filter: ml.Expression.raw([
            'all',
            [
              '==',
              ['get', 'isPrimary'],
              false,
            ],
            [
              '==',
              ['get', 'isAdministrative'],
              false,
            ],
          ]),
          iconImage: ml.Expression.image(
            ml.Expression.get('labelImage').asString(),
          ),
          iconAnchor: const ml.Literal(ml.IconAnchor.left),
          iconOffset: const ml.Literal(Offset(5, 0)),
          iconAllowOverlap: const ml.Literal(false),
          iconIgnorePlacement: const ml.Literal(false),
          iconOptional: const ml.Literal(false),
          iconSize: const ml.Literal(1),
          iconOpacity: _citySecondaryLabelOpacityExpression,
          sortKey: ml.Expression.get('sortKey').asNumber(),
          zOrder: const ml.Literal(ml.SymbolZOrder.source),
          visible: _referenceVisible,
        ),
      );
      _annotationStyleLayerIds.add(_citySecondaryLabelLayerId);
    }
    for (var tier = 0; tier < _departmentLabelLayerIds.length; tier++) {
      final layerId = _departmentLabelLayerIds[tier];
      if (style.layers[layerId] != null) continue;
      await style.layers.add(
        ml.SymbolStyleLayer(
          id: layerId,
          sourceId: _cityAnnotationSourceId,
          filter: ml.Expression.raw([
            'all',
            [
              '==',
              ['get', 'isAdministrative'],
              true,
            ],
            [
              '==',
              ['get', 'minZoomTier'],
              tier,
            ],
          ]),
          iconImage: ml.Expression.image(
            ml.Expression.get('labelImage').asString(),
          ),
          iconAnchor: const ml.Literal(ml.IconAnchor.center),
          iconAllowOverlap: const ml.Literal(false),
          iconIgnorePlacement: const ml.Literal(false),
          iconOptional: const ml.Literal(false),
          iconSize: const ml.Literal(1),
          iconOpacity: const ml.Literal(0),
          sortKey: ml.Expression.get('sortKey').asNumber(),
          zOrder: const ml.Literal(ml.SymbolZOrder.source),
          visible: _referenceVisible,
        ),
      );
      _annotationStyleLayerIds.add(layerId);
    }
    if (style.layers[_locationAccuracyLayerId] == null) {
      await style.layers.add(
        ml.CircleStyleLayer(
          id: _locationAccuracyLayerId,
          sourceId: _locationSourceId,
          filter: ml.Expression.raw([
            '==',
            ['get', 'hasAccuracy'],
            true,
          ]),
          radius: _locationAccuracyRadiusExpression,
          color: const ml.Literal(Color(0x1F1976D2)),
          opacity: const ml.Literal(1),
          strokeWidth: const ml.Literal(1),
          strokeColor: const ml.Literal(Color(0x6B1976D2)),
          strokeOpacity: const ml.Literal(1),
        ),
      );
      _annotationStyleLayerIds.add(_locationAccuracyLayerId);
    }
    if (style.layers[_locationMarkerLayerId] == null) {
      await style.layers.add(
        ml.SymbolStyleLayer(
          id: _locationMarkerLayerId,
          sourceId: _locationSourceId,
          filter: ml.Expression.raw([
            '==',
            ['get', 'iconImage'],
            _locationImageId,
          ]),
          iconImage: ml.Expression.image(
            ml.Expression.get('iconImage').asString(),
          ),
          iconAnchor: const ml.Literal(ml.IconAnchor.center),
          iconAllowOverlap: const ml.Literal(true),
          iconIgnorePlacement: const ml.Literal(true),
          iconSize: const ml.Literal(1),
        ),
      );
      _annotationStyleLayerIds.add(_locationMarkerLayerId);
    }
    if (style.layers[_personalMarkerCircleLayerId] == null) {
      await style.layers.add(
        ml.CircleStyleLayer(
          id: _personalMarkerCircleLayerId,
          sourceId: _personalMarkerSourceId,
          radius: const ml.Literal(18),
          color: ml.Literal(_surfaceColor),
          opacity: const ml.Literal(1),
          strokeWidth: const ml.Literal(0.5),
          strokeColor: ml.Literal(_surfaceColor),
          strokeOpacity: const ml.Literal(1),
          translate: const ml.Literal(Offset(0, -22)),
          translateAnchor: const ml.Literal(ml.CircleTranslateAnchor.viewport),
          sortKey: ml.Expression.get('sortKey').asNumber(),
        ),
      );
      _annotationStyleLayerIds.add(_personalMarkerCircleLayerId);
    }
    if (style.layers[_personalMarkerLayerId] == null) {
      await style.layers.add(
        ml.SymbolStyleLayer(
          id: _personalMarkerLayerId,
          sourceId: _personalMarkerSourceId,
          iconImage: ml.Expression.image(
            ml.Expression.get('iconImage').asString(),
          ),
          iconAnchor: const ml.Literal(ml.IconAnchor.bottom),
          iconAllowOverlap: const ml.Literal(true),
          iconIgnorePlacement: const ml.Literal(true),
          iconSize: const ml.Literal(1),
          sortKey: ml.Expression.get('sortKey').asNumber(),
          zOrder: const ml.Literal(ml.SymbolZOrder.source),
        ),
      );
      _annotationStyleLayerIds.add(_personalMarkerLayerId);
    }
    _nativeAnnotationLayersReady = true;
    _setNativeReferenceVisibility(_referenceVisible);
  }

  void _moveNativeAnnotationLayersToTop() {
    final layers = _style?.layers;
    if (layers == null) return;
    for (final id in [
      _cityDotLayerId,
      _citySecondaryDotLayerId,
      _citySecondaryLabelLayerId,
      ..._departmentLabelLayerIds,
      _cityLabelLayerId,
      _locationAccuracyLayerId,
      _locationMarkerLayerId,
      _personalMarkerCircleLayerId,
      _personalMarkerLayerId,
    ]) {
      if (layers[id] != null) layers.move(id);
    }
  }

  void _setNativeReferenceVisibility(bool visible) {
    final dot = _style?.layers[_cityDotLayerId];
    final secondaryDot = _style?.layers[_citySecondaryDotLayerId];
    final label = _style?.layers[_cityLabelLayerId];
    final secondaryLabel = _style?.layers[_citySecondaryLabelLayerId];
    if (dot is ml.CircleStyleLayer) dot.visible = visible;
    if (secondaryDot is ml.CircleStyleLayer) secondaryDot.visible = visible;
    if (label is ml.SymbolStyleLayer) label.visible = visible;
    if (secondaryLabel is ml.SymbolStyleLayer) {
      secondaryLabel.visible = visible;
    }
    for (final id in _departmentLabelLayerIds) {
      final layer = _style?.layers[id];
      if (layer is ml.SymbolStyleLayer) layer.visible = visible;
    }
  }

  void _onAnnotationSettingsChanged() {
    unawaited(_syncNativeAnnotationSources());
  }

  static ml.Expression<num> get _cityBaseOpacityExpression =>
      ml.Expression.raw([
        'interpolate',
        ['linear'],
        ['zoom'],
        4,
        0.78,
        6.5,
        0.96,
        24,
        0.96,
      ]);

  static ml.Expression<num> get _citySecondaryVisibilityExpression =>
      ml.Expression.raw([
        'interpolate',
        ['linear'],
        ['zoom'],
        6.7,
        0,
        8.4,
        1,
        24,
        1,
      ]);

  static ml.Expression<num> get _citySecondaryLabelOpacityExpression =>
      ml.Expression.raw([
        'interpolate',
        ['linear'],
        ['zoom'],
        4,
        0,
        6.7,
        0,
        8.4,
        0.96,
        24,
        0.96,
      ]);

  void _updateAdministrativeLabelOpacity(double zoom) {
    for (var tier = 0; tier < _departmentLabelLayerIds.length; tier++) {
      final layer = _style?.layers[_departmentLabelLayerIds[tier]];
      if (layer is! ml.SymbolStyleLayer) continue;
      layer.iconOpacity = ml.Literal(
        jurisdictionLabelOpacityForTier(tier: tier, zoom: zoom),
      );
    }
  }

  static ml.Expression<num> get _locationAccuracyRadiusExpression {
    const metersPerPixelAtZoomZero = 78271.51696402048;
    const radiansPerDegree = math.pi / 180;
    return ml.Expression.raw([
      'interpolate',
      ['exponential', 2],
      ['zoom'],
      for (var zoom = 0; zoom <= 24; zoom++) ...[
        zoom,
        [
          'max',
          24,
          [
            '/',
            [
              '*',
              ['get', 'accuracyMeters'],
              math.pow(2, zoom),
            ],
            [
              '*',
              metersPerPixelAtZoomZero,
              [
                'cos',
                [
                  '*',
                  ['get', 'latitude'],
                  radiansPerDegree,
                ],
              ],
            ],
          ],
        ],
      ],
    ]);
  }

  Future<HttpServer> _ensureTileServer() async {
    final existing = _tileServer;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _tileServer = server;
    server.listen(
      (request) => unawaited(_serveTileRequest(request)),
      onError: (_) {},
    );
    return server;
  }

  Future<void> _serveTileRequest(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length != 4) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final archive = _archives[segments[0]];
    final zoom = int.tryParse(segments[1]);
    final x = int.tryParse(segments[2]);
    final y = int.tryParse(segments[3].split('.').first);
    if (archive == null || zoom == null || x == null || y == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final tile = await archive.tile(ZXY(zoom, x, y).toTileId());
      final bytes = tile.bytes();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'x-protobuf')
        ..headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=86400')
        ..add(bytes);
      await request.response.close();
    } on TileNotFoundException {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  @override
  void setSelectedSoilFeature(String? featureId, {GisFeature? feature}) {
    if (feature != null) _selectedFeature = feature;
    if (featureId == null) _selectedFeature = null;
    unawaited(_syncSelectedFeature());
  }

  Future<void> _syncSelectedFeature() async {
    if (_disposed) return;
    final style = _style;
    if (style == null) return;
    final feature = _selectedFeature;
    final source = feature == null ? null : _sourceForFeature(feature);
    final selector = feature == null
        ? null
        : MapLibreFeatureSelector.forFeature(
            featureId: feature.id,
            properties: feature.properties,
          );
    _selectedSourceId = selector?.isUsable == true ? source?.id : null;
    for (final entry in _selectionLayersBySource.entries) {
      final isSelected = entry.key == _selectedSourceId;
      entry.value
        ..filter = isSelected ? selector!.filter : _noFeatureFilter
        ..visible = _soilVisible && isSelected;
      final outline = _selectionOutlineLayersBySource[entry.key];
      if (outline != null) {
        outline
          ..filter = isSelected ? selector!.filter : _noFeatureFilter
          ..visible = _soilVisible && isSelected;
      }
    }
  }

  GisNativeMapSource? _sourceForFeature(GisFeature feature) {
    final separator = feature.id.indexOf(':');
    if (separator > 0) {
      final coverageId = feature.id.substring(0, separator);
      return _sources
          .where((source) => source.coverageId == coverageId)
          .firstOrNull;
    }
    return _sources.where((source) => source.defaultCoverage).firstOrNull ??
        (_sources.length == 1 ? _sources.single : null);
  }

  Future<void> _syncMeasurementSources() async {
    if (_disposed) return;
    final hasMeasurementData =
        _distanceMeasurementPoints.isNotEmpty ||
        _areaMeasurementPoints.isNotEmpty ||
        _measurementMarkers.isNotEmpty ||
        _savedMeasurements.isNotEmpty ||
        _lastMeasurementData != null;
    if (!hasMeasurementData) return;
    await _styleReady.future;
    if (_disposed) return;
    await _ensureMeasurementStyleSetup();
    if (_disposed) return;
    var data = MapLibreMeasurementData.build(
      distancePoints: _distanceMeasurementPoints,
      areaPoints: _areaMeasurementPoints,
      activeMarkers: _measurementMarkers,
      activeColor: _measurementColor,
      savedMeasurements: _savedMeasurements,
      highlightedId: _highlightedMeasurementId,
      hoveredId: _hoveredMeasurementId,
      snapshotVersion: _measurementSnapshotVersion,
    );
    final previous = _lastMeasurementData;
    if (previous != null &&
        previous.active == data.active &&
        previous.saved == data.saved) {
      return;
    }
    data = MapLibreMeasurementData.build(
      distancePoints: _distanceMeasurementPoints,
      areaPoints: _areaMeasurementPoints,
      activeMarkers: _measurementMarkers,
      activeColor: _measurementColor,
      savedMeasurements: _savedMeasurements,
      highlightedId: _highlightedMeasurementId,
      hoveredId: _hoveredMeasurementId,
      snapshotVersion: ++_measurementSnapshotVersion,
    );
    await _measurementUpdatePump.submit(data);
  }

  @override
  void setProvinceBoundaryHighlight({
    required String coverageId,
    required List<List<LatLng>>? rings,
    required Color fillColor,
    required Color borderColor,
  }) {
    if (_disposed || defaultTargetPlatform != TargetPlatform.android) return;
    if (rings == null || rings.isEmpty) {
      if (_provinceHighlights.remove(coverageId) == null) return;
    } else {
      final previous = _provinceHighlights[coverageId];
      if (previous != null &&
          identical(previous.rings, rings) &&
          previous.fillColor == fillColor &&
          previous.borderColor == borderColor) {
        return;
      }
      _provinceHighlights[coverageId] = _ProvinceHighlight(
        rings: rings,
        fillColor: fillColor,
        borderColor: borderColor,
      );
    }
    unawaited(_syncProvinceHighlights());
  }

  Future<void> _syncProvinceHighlights() async {
    if (_disposed) return;
    _provinceHighlightSyncRequested = true;
    final current = _provinceHighlightSyncFuture;
    if (current != null) return current;
    final sync = () async {
      await _styleReady.future;
      while (_provinceHighlightSyncRequested && !_disposed) {
        _provinceHighlightSyncRequested = false;
        await _sourceInstallQueue.run(_syncProvinceHighlightsNow);
      }
    }();
    _provinceHighlightSyncFuture = sync;
    try {
      await sync;
    } finally {
      if (identical(_provinceHighlightSyncFuture, sync)) {
        _provinceHighlightSyncFuture = null;
      }
      if (_provinceHighlightSyncRequested && !_disposed) {
        unawaited(_syncProvinceHighlights());
      }
    }
  }

  Future<void> _syncProvinceHighlightsNow() async {
    final style = _style;
    if (_disposed || style == null) return;
    await _ensureProvinceHighlightLayers(style);
    final snapshot = MapLibreProvinceHighlightData.build(
      provinces: {
        for (final entry in _provinceHighlights.entries)
          entry.key: entry.value.rings,
      },
      fillColors: {
        for (final entry in _provinceHighlights.entries)
          entry.key: entry.value.fillColor,
      },
      borderColors: {
        for (final entry in _provinceHighlights.entries)
          entry.key: entry.value.borderColor,
      },
      revision: ++_provinceHighlightSnapshotVersion,
    );
    await _provinceHighlightUpdatePump.submit(snapshot);
    _moveProvinceHighlightLayersToTop();
  }

  Future<void> _ensureProvinceHighlightLayers(ml.StyleController style) async {
    if (style.sources[_provinceHighlightSourceId] == null) {
      await style.sources.add(
        ml.GeoJsonSource.data(
          id: _provinceHighlightSourceId,
          data: MapLibreProvinceHighlightData.build(
            provinces: const {},
            fillColors: const {},
            borderColors: const {},
            revision: _provinceHighlightSnapshotVersion,
          ).geoJson,
        ),
      );
    }
    if (style.layers[_provinceHighlightFillId] == null) {
      await style.layers.add(
        ml.FillStyleLayer(
          id: _provinceHighlightFillId,
          sourceId: _provinceHighlightSourceId,
          color: ml.Expression.get('fillColor').convertToColor(),
          opacity: ml.Expression.get('fillOpacity').asNumber(),
        ),
      );
      _provinceHighlightLayerIds.add(_provinceHighlightFillId);
    }
    if (style.layers[_provinceHighlightOutlineId] == null) {
      await style.layers.add(
        ml.LineStyleLayer(
          id: _provinceHighlightOutlineId,
          sourceId: _provinceHighlightSourceId,
          color: ml.Expression.get('borderColor').convertToColor(),
          opacity: ml.Expression.get('borderOpacity').asNumber(),
          width: const ml.Literal(1.5),
        ),
      );
      _provinceHighlightLayerIds.add(_provinceHighlightOutlineId);
    }
  }

  Future<void> _applyProvinceHighlightData(
    MapLibreProvinceHighlightData data,
  ) async {
    if (_disposed) return;
    final style = _style;
    if (style == null) return;
    await style.sources.updateGeoJsonData(
      _provinceHighlightSourceId,
      data.geoJson,
    );
    _lastProvinceHighlightData = data.geoJson;
  }

  void _moveProvinceHighlightLayersToTop() {
    final layers = _style?.layers;
    if (layers == null) return;
    for (final id in [_provinceHighlightFillId, _provinceHighlightOutlineId]) {
      if (layers[id] != null) layers.move(id);
    }
  }

  Future<void> _ensureMeasurementStyleSetup() {
    final existing = _measurementSetupFuture;
    if (existing != null) return existing;
    final setup = _sourceInstallQueue.run(_ensureMeasurementSourcesAndLayers);
    _measurementSetupFuture = setup;
    return setup.catchError((Object error, StackTrace stackTrace) {
      if (identical(_measurementSetupFuture, setup)) {
        _measurementSetupFuture = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> _applyMeasurementData(MapLibreMeasurementData data) async {
    if (_disposed) return;
    final style = _style;
    if (style == null) return;
    await _ensureMeasurementVertexImages(style, data.active);
    final previous = _lastMeasurementData;
    if (previous?.active != data.active) {
      await style.sources.updateGeoJsonData(
        _activeMeasurementSourceId,
        data.active,
      );
    }
    if (previous?.saved != data.saved) {
      await style.sources.updateGeoJsonData(
        _savedMeasurementSourceId,
        data.saved,
      );
    }
    _lastMeasurementData = data;
  }

  Future<void> _ensureMeasurementVertexImages(
    ml.StyleController style,
    String activeData,
  ) async {
    final features =
        (jsonDecode(activeData) as Map<String, dynamic>)['features'] as List;
    for (final rawFeature in features) {
      final feature = rawFeature as Map<String, dynamic>;
      final properties = feature['properties'] as Map<String, dynamic>;
      if (properties['kind'] != 'active-vertex') continue;
      if (properties['useFlutterOverlay'] == true) continue;
      final imageId = properties['imageId'] as String;
      if (!_registeredMeasurementImages.add(imageId)) continue;
      try {
        final label = properties['label'] as String;
        final colorValue = int.parse(
          (properties['textColor'] as String).substring(1),
          radix: 16,
        );
        await style.addImageFromCanvas(
          id: imageId,
          width: 44,
          height: 44,
          painter: (canvas) {
            final painter = TextPainter(
              text: TextSpan(
                text: label,
                style: TextStyle(
                  color: Color(0xFF000000 | colorValue),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              textDirection: TextDirection.ltr,
              textScaler: TextScaler.noScaling,
            )..layout(maxWidth: 40);
            painter.paint(
              canvas,
              Offset((44 - painter.width) / 2, (44 - painter.height) / 2),
            );
          },
        );
      } catch (_) {
        _registeredMeasurementImages.remove(imageId);
        rethrow;
      }
    }
  }

  Future<void> _ensureMeasurementSourcesAndLayers() async {
    final style = _style;
    if (style == null) return;
    for (final id in [_activeMeasurementSourceId, _savedMeasurementSourceId]) {
      if (style.sources[id] == null) {
        await style.sources.add(
          ml.GeoJsonSource.data(id: id, data: _emptyFeatureCollection),
        );
      }
    }
    if (_measurementStyleLayerIds.any((id) => style.layers[id] == null)) {
      _measurementStyleLayerIds.clear();
      _registeredMeasurementImages.clear();
      _lastMeasurementData = null;
    }
    if (_measurementStyleLayerIds.isNotEmpty) {
      _moveMeasurementLayersToTop();
      return;
    }

    await _addMeasurementLayer(
      MapLibreMeasurementStyles.line(
        id: _activeDistanceLineId,
        sourceId: _activeMeasurementSourceId,
        filter: _kindFilter('active-distance'),
        color: _featureColor,
        stroke: MeasurementRenderStyles.activeDistance,
      ),
    );
    await _addMeasurementLayer(
      MapLibreMeasurementStyles.areaFill(
        id: _activeAreaFillId,
        sourceId: _activeMeasurementSourceId,
        filter: _kindFilter('active-area'),
        color: _featureColor,
        opacity: MeasurementRenderStyles.activeAreaFillOpacity,
      ),
    );
    await _addMeasurementLayer(
      MapLibreMeasurementStyles.line(
        id: _activeAreaOutlineId,
        sourceId: _activeMeasurementSourceId,
        filter: _kindFilter('active-area-outline'),
        color: _featureColor,
        stroke: MeasurementRenderStyles.activeAreaOutline,
      ),
    );
    await _addMeasurementLayer(
      ml.CircleStyleLayer(
        id: _activeVertexCircleId,
        sourceId: _activeMeasurementSourceId,
        filter: _nativeActiveVertexFilter,
        radius: ml.Expression.get('radius').asNumber(),
        color: ml.Expression.get('fillColor').convertToColor(),
        strokeWidth: ml.Expression.get('strokeWidth').asNumber(),
        strokeColor: ml.Expression.get('strokeColor').convertToColor(),
      ),
    );
    await _addMeasurementLayer(
      ml.SymbolStyleLayer(
        id: _activeVertexLabelsId,
        sourceId: _activeMeasurementSourceId,
        filter: _nativeActiveVertexFilter,
        sortKey: ml.Expression.get('sortKey').asNumber(),
        iconImage: ml.Expression.image(ml.Expression.get('imageId').asString()),
        iconAnchor: const ml.Literal(ml.IconAnchor.center),
        iconSize: const ml.Literal(1),
        iconAllowOverlap: const ml.Literal(true),
        iconIgnorePlacement: const ml.Literal(true),
      ),
    );

    for (final (state, visualState, suffix) in [
      ('normal', SavedMeasurementVisualState.normal, 'normal'),
      ('hovered', SavedMeasurementVisualState.hovered, 'hovered'),
      ('selected', SavedMeasurementVisualState.selected, 'selected'),
    ]) {
      final measurementStyle = MeasurementRenderStyles.saved(visualState);
      await _addMeasurementLayer(
        ml.FillStyleLayer(
          id: _savedAreaLayerId(suffix),
          sourceId: _savedMeasurementSourceId,
          filter: _kindAndStateFilter('saved-area', state),
          color: _featureColor,
          opacity: ml.Literal(measurementStyle.areaFillOpacity),
        ),
      );
      await _addMeasurementLayer(
        MapLibreMeasurementStyles.line(
          id: _savedAreaOutlineLayerId(suffix),
          sourceId: _savedMeasurementSourceId,
          filter: _kindAndStateFilter('saved-area-outline', state),
          color: _featureColor,
          stroke: measurementStyle.areaOutline,
        ),
      );
      await _addMeasurementLayer(
        MapLibreMeasurementStyles.line(
          id: _savedDistanceLineLayerId(suffix),
          sourceId: _savedMeasurementSourceId,
          filter: _kindAndStateFilter('saved-distance', state),
          color: _featureColor,
          stroke: measurementStyle.distance,
        ),
      );
    }

    _moveMeasurementLayersToTop();
  }

  Future<void> _addMeasurementLayer(ml.StyleLayer layer) async {
    final style = _style;
    if (style == null || style.layers[layer.id] != null) return;
    await style.layers.add(layer);
    _measurementStyleLayerIds.add(layer.id);
  }

  void _moveMeasurementLayersToTop() {
    final layers = _style?.layers;
    if (layers == null) return;
    for (final id in _measurementLayerOrderBottomToTop) {
      if (layers[id] != null) layers.move(id);
    }
    _moveProvinceHighlightLayersToTop();
  }

  static ml.Expression<Color> get _featureColor =>
      ml.Expression.get('color').convertToColor();

  static ml.Expression<bool> _kindFilter(String kind) => ml.Expression.raw([
    '==',
    ['get', 'kind'],
    kind,
  ]);

  static final ml.Expression<bool> _nativeActiveVertexFilter =
      ml.Expression.raw([
        'all',
        [
          '==',
          ['get', 'kind'],
          'active-vertex',
        ],
        [
          '==',
          ['get', 'useFlutterOverlay'],
          false,
        ],
      ]);

  static ml.Expression<bool> _kindAndStateFilter(String kind, String state) =>
      ml.Expression.raw([
        'all',
        [
          '==',
          ['get', 'kind'],
          kind,
        ],
        [
          '==',
          ['get', 'state'],
          state,
        ],
      ]);

  static String _savedAreaLayerId(String state) => switch (state) {
    'hovered' => _savedAreaHoveredId,
    'selected' => _savedAreaSelectedId,
    _ => _savedAreaNormalId,
  };

  static String _savedAreaOutlineLayerId(String state) => switch (state) {
    'hovered' => _savedAreaLineHoveredId,
    'selected' => _savedAreaLineSelectedId,
    _ => _savedAreaLineNormalId,
  };

  static String _savedDistanceLineLayerId(String state) => switch (state) {
    'hovered' => _savedDistanceLineHoveredId,
    'selected' => _savedDistanceLineSelectedId,
    _ => _savedDistanceLineNormalId,
  };

  @override
  Future<GisFeature?> hitTestSoilFeature(Offset screenOffset) async {
    final controller = _controller;
    if (controller == null || _sources.isEmpty) return null;
    final rendered = await controller.featuresAtPoint(
      screenOffset,
      layerIds: [for (final source in _sources) '${source.id}$_fillSuffix'],
    );
    if (rendered.isEmpty) return null;
    final feature = rendered.first;
    final source = _sources
        .where((item) => item.id == feature.sourceId)
        .firstOrNull;
    if (source == null || feature.geometry == null) return null;
    final nativeId = feature.id;
    final hasStableTileId = nativeId != null && nativeId.toString() != '0';
    final rawId = hasStableTileId
        ? nativeId.toString()
        : _fallbackFeatureId(feature);
    final appId = source.defaultCoverage
        ? rawId
        : '${source.coverageId}:$rawId';
    final properties = Map<String, Object?>.from(feature.properties);
    return GisFeature(
      id: appId,
      geometry: GisGeometry(
        type: feature.geometry!['type']?.toString() ?? '',
        coordinates: feature.geometry!['coordinates'],
      ),
      properties: properties,
      locality: (properties['locality'] ?? properties['localidad'] ?? '')
          .toString(),
      soilMapId: _readInt(properties['soilMapId'] ?? properties['soil_map_id']),
    );
  }

  String _fallbackFeatureId(ml.RenderedFeature feature) {
    final canonical = jsonEncode({
      'sourceLayer': feature.sourceLayer,
      'geometry': feature.geometry,
      'properties': feature.properties,
    });
    return 'native-${_hash32(canonical, 0x811c9dc5)}'
        '${_hash32(canonical, 0x9e3779b9)}';
  }

  String _hash32(String value, int seed) {
    var hash = seed;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  int _readInt(Object? value) => switch (value) {
    final int number => number,
    final num number => number.toInt(),
    final String text => int.tryParse(text) ?? 0,
    _ => 0,
  };

  @override
  void setSoilPolygonsVisible(bool visible) {
    _soilVisible = visible;
    for (final layer in _fillLayers.values) {
      layer.visible = visible;
    }
    for (final layer in _outlineLayersBySource.values) {
      layer.visible = visible;
    }
    for (final entry in _selectionLayersBySource.entries) {
      entry.value.visible = visible && entry.key == _selectedSourceId;
    }
    for (final entry in _selectionOutlineLayersBySource.entries) {
      entry.value.visible = visible && entry.key == _selectedSourceId;
    }
    _lastReferenceZoom = null;
    _updateReferenceLayerVisibility(camera.zoom);
    unawaited(_syncNativeAnnotationSources());
  }

  @override
  void setReferenceBasemapVisible(bool visible) {
    if (_referenceVisible != visible) _lastReferenceZoom = null;
    _referenceVisible = visible;
    final background = _style?.layers[_referenceBackgroundId];
    if (background is ml.BackgroundStyleLayer) {
      background.color = ml.Literal(
        visible ? _referenceBackgroundColor : _surfaceColor,
      );
    }
    _setNativeReferenceVisibility(visible);
    _updateReferenceLayerVisibility(camera.zoom);
  }

  @override
  Future<void> loadReferenceBasemap({required List<String> assetPaths}) async {
    if (assetPaths.isEmpty) {
      await _styleReady.future;
      if (_disposed) return;
      _referenceLoaded = true;
      setReferenceBasemapVisible(false);
      await _syncNativeAnnotationSources();
      return;
    }

    final loadClock = Stopwatch()..start();
    _referenceBasemapClock = loadClock;
    final assetReadClock = Stopwatch()..start();
    final documents = await Future.wait(
      assetPaths.map(
        (assetPath) async =>
            MapEntry(assetPath, await rootBundle.loadString(assetPath)),
      ),
    );
    assetReadClock.stop();
    if (_disposed) return;
    final decodeClock = Stopwatch()..start();
    final data = MapLibreReferenceBasemapData.fromAssetJson(documents);
    decodeClock.stop();
    if (kProfileMode) {
      debugPrint(
        'GIS_LABEL_TIMING asset_read_ms=${assetReadClock.elapsedMilliseconds}',
      );
      debugPrint(
        'GIS_LABEL_TIMING json_decode_ms=${decodeClock.elapsedMilliseconds}',
      );
    }
    final styleWaitClock = Stopwatch()..start();
    await _styleReady.future;
    styleWaitClock.stop();
    if (_disposed) return;
    final style = _style;
    if (style == null) return;
    if (kProfileMode) {
      debugPrint(
        'GIS_LABEL_TIMING style_wait_ms=${styleWaitClock.elapsedMilliseconds}',
      );
    }
    _referenceCities = data.cities;
    // Sprite generation depends only on the decoded labels and loaded style,
    // not on the GeoJSON line sources. Start it while those sources/layers
    // are being installed so first labels do not wait for unrelated setup.
    _scheduleCityLabelImageRegistration(style);
    final belowLayerId = _referenceLayerInsertionPoint;

    for (final entry in data.featureCollections.entries) {
      final sourceId = _referenceSourceId(entry.key);
      if (style.sources[sourceId] == null) {
        await style.sources.add(
          ml.GeoJsonSource.data(id: sourceId, data: entry.value),
        );
      } else {
        await style.sources.updateGeoJsonData(sourceId, entry.value);
      }
    }

    for (final spec in _referenceStyleSpecs) {
      if (_referenceLayers.containsKey(spec.layerId)) continue;
      final layer = ml.LineStyleLayer(
        id: spec.layerId,
        sourceId: _referenceSourceId(spec.category),
        color: ml.Literal(spec.color),
        width: ml.Literal(spec.width),
        opacity: const ml.Literal(1),
        cap: const ml.Literal(ml.LineCap.round),
        join: const ml.Literal(ml.LineJoin.round),
        visible: _referenceVisible,
      );
      await style.layers.add(layer, belowLayerId: belowLayerId);
      _referenceLayers[spec.layerId] = layer;
    }

    _referenceLoaded = true;
    await _ensureAdministrativeBoundaryLayers(style);
    setReferenceBasemapVisible(_referenceVisible);
    _lastReferenceZoom = null;
    _updateReferenceLayerVisibility(camera.zoom);
    _updateAdministrativeLabelOpacity(camera.zoom);
    await _syncNativeAnnotationSources();
    if (kProfileMode) {
      debugPrint(
        'GIS_LABEL_TIMING sources_layers_ready_ms=${loadClock.elapsedMilliseconds}',
      );
    }
  }

  Future<void> _ensureAdministrativeBoundaryLayers(
    ml.StyleController style,
  ) async {
    final sourceId = _referenceSourceId('departmentBoundaries');
    for (final entry in _administrativeBoundaryLayerIds.entries) {
      if (style.layers[entry.value] != null) continue;
      final initial = administrativeBoundaryStyleAtZoom(
        enhancedForSoilPolygons: false,
        zoom: camera.zoom,
      );
      await style.layers.add(
        ml.LineStyleLayer(
          id: entry.value,
          sourceId: sourceId,
          filter: ml.Expression.raw([
            '==',
            ['get', 'provinceId'],
            entry.key,
          ]),
          color: ml.Literal(initial.color),
          width: ml.Literal(initial.strokeWidth),
          opacity: ml.Literal(initial.opacity),
          cap: const ml.Literal(ml.LineCap.round),
          join: const ml.Literal(ml.LineJoin.round),
          visible: _referenceVisible,
        ),
      );
    }
    _moveAdministrativeBoundaryLayersToTop();
  }

  void _moveAdministrativeBoundaryLayersToTop() {
    final layers = _style?.layers;
    if (layers == null) return;
    for (final id in _administrativeBoundaryLayerIds.values) {
      if (layers[id] != null) layers.move(id);
    }
  }

  String? get _referenceLayerInsertionPoint =>
      _fillLayers.keys.firstOrNull ??
      _selectionLayersBySource.values.firstOrNull?.id;

  String _referenceSourceId(String category) =>
      MapLibreReferenceBasemapData.sourceIdForCategory(category);

  void _updateReferenceLayerVisibility(double zoom) {
    if (!_referenceLoaded || !zoom.isFinite || _lastReferenceZoom == zoom) {
      return;
    }
    _lastReferenceZoom = zoom;
    final geometryOpacity = _referenceVisible && zoom < 13 ? 1.0 : 0.0;
    for (final spec in _referenceStyleSpecs) {
      final layer = _referenceLayers[spec.layerId];
      if (layer == null) continue;
      if (layer.visible != _referenceVisible) layer.visible = _referenceVisible;
      final thresholdOpacity = spec.fadeStart == null
          ? 1.0
          : ((zoom - spec.fadeStart!) / (spec.fadeEnd! - spec.fadeStart!))
                .clamp(0.0, 1.0);
      layer.opacity = ml.Literal(geometryOpacity * thresholdOpacity);
    }
    for (final entry in _administrativeBoundaryLayerIds.entries) {
      final layer = _style?.layers[entry.value];
      if (layer is! ml.LineStyleLayer) continue;
      layer.visible = _referenceVisible;
      final enhanced =
          _soilVisible &&
          _sources.any((source) => source.coverageId == entry.key);
      final boundaryStyle = administrativeBoundaryStyleAtZoom(
        enhancedForSoilPolygons: enhanced,
        zoom: zoom,
      );
      layer
        ..color = ml.Literal(boundaryStyle.color)
        ..width = ml.Literal(boundaryStyle.strokeWidth)
        ..opacity = ml.Literal(_referenceVisible ? boundaryStyle.opacity : 0);
    }
    _updateAdministrativeLabelOpacity(zoom);
  }

  @override
  void setPersonalMarkers(
    List<SoilMapMarkerPin> markers, {
    required ValueChanged<String> onMarkerTap,
  }) {
    final next = List<SoilMapMarkerPin>.unmodifiable(markers);
    final dataChanged =
        MapLibreGeographicAnnotationData.personalMarkers(next) !=
        MapLibreGeographicAnnotationData.personalMarkers(_personalMarkers);
    _personalMarkers = next;
    _onMarkerTap = onMarkerTap;
    if (dataChanged) unawaited(_syncNativeAnnotationSources());
  }

  @override
  void setCurrentLocationMarker({
    LatLng? point,
    double? accuracyMeters,
    required bool showAccuracyCircle,
  }) {
    final changed =
        _currentLocation != point ||
        _currentLocationAccuracyMeters != accuracyMeters ||
        _showAccuracyCircle != showAccuracyCircle;
    _currentLocation = point;
    _currentLocationAccuracyMeters = accuracyMeters;
    _showAccuracyCircle = showAccuracyCircle;
    if (changed) unawaited(_syncNativeAnnotationSources());
  }

  @override
  void setSavedMeasurementGeometry({
    required List<SavedMeasurement> measurements,
    String? highlightedId,
    String? hoveredId,
    ValueChanged<String?>? onHoverChanged,
  }) {
    if (_disposed) return;
    _savedMeasurements = List.unmodifiable(measurements);
    _highlightedMeasurementId = highlightedId;
    _hoveredMeasurementId = hoveredId;
    _onSavedMeasurementHoverChanged = onHoverChanged;
    unawaited(_syncMeasurementSources());
    unawaited(_syncNativeAnnotationSources());
  }

  void _updateHoveredSavedMeasurement(Offset position) {
    if (_disposed) return;
    final controller = _controller;
    if (controller == null) return;
    String? next;
    for (final measurement in _savedMeasurements.reversed) {
      final points = measurement.geometry;
      if (points.length < 2) continue;
      final segmentCount = measurement.type == SavedMeasurementType.area
          ? points.length
          : points.length - 1;
      for (var index = 0; index < segmentCount; index++) {
        final start = controller.toScreenLocation(
          ml.Geographic(
            lon: points[index].longitude,
            lat: points[index].latitude,
          ),
        );
        final end = controller.toScreenLocation(
          ml.Geographic(
            lon: points[(index + 1) % points.length].longitude,
            lat: points[(index + 1) % points.length].latitude,
          ),
        );
        if (_distanceToScreenSegment(position, start, end) <= 10) {
          next = measurement.id;
          break;
        }
      }
      if (next != null) break;
    }
    if (next != _hoveredMeasurementId) {
      _hoveredMeasurementId = next;
      _onSavedMeasurementHoverChanged?.call(next);
      unawaited(_syncMeasurementSources());
    }
  }

  double _distanceToScreenSegment(Offset point, Offset start, Offset end) {
    final segment = end - start;
    final lengthSquared = segment.distanceSquared;
    if (lengthSquared == 0) return (point - start).distance;
    final t =
        (((point - start).dx * segment.dx + (point - start).dy * segment.dy) /
                lengthSquared)
            .clamp(0.0, 1.0);
    return (point - (start + segment * t)).distance;
  }

  @override
  void setMeasurementGeometry({
    required List<LatLng> distancePoints,
    required List<LatLng> areaPoints,
    required Color color,
    List<SoilMapMeasurementMarker> markers = const [],
  }) {
    if (_disposed) return;
    _distanceMeasurementPoints = List.unmodifiable(distancePoints);
    _areaMeasurementPoints = List.unmodifiable(areaPoints);
    _measurementColor = color;
    _measurementMarkers = List.unmodifiable(markers);
    unawaited(_syncMeasurementSources());
  }

  @override
  void dispose() {
    _disposed = true;
    SettingsService.instance.removeListener(_onAnnotationSettingsChanged);
    if (!_styleReady.isCompleted) _styleReady.complete();
    _controller = null;
    _style = null;
    _fillLayers.clear();
    _outlineLayersBySource.clear();
    _selectionLayersBySource.clear();
    _selectionOutlineLayersBySource.clear();
    _referenceLayers.clear();
    _selectedSourceId = null;
    _selectedFeature = null;
    _personalMarkers = const [];
    _onMarkerTap = null;
    _referenceCities = const [];
    _currentLocation = null;
    _currentLocationAccuracyMeters = null;
    _showAccuracyCircle = false;
    _distanceMeasurementPoints = const [];
    _areaMeasurementPoints = const [];
    _measurementMarkers = const [];
    _savedMeasurements = const [];
    _onSavedMeasurementHoverChanged = null;
    _lastMeasurementData = null;
    _lastProvinceHighlightData = null;
    _measurementSetupFuture = null;
    _measurementStyleLayerIds.clear();
    _provinceHighlightLayerIds.clear();
    _registeredMeasurementImages.clear();
    _annotationStyleLayerIds.clear();
    _registeredAnnotationImages.clear();
    _lastCityAnnotationData = null;
    _lastPersonalMarkerData = null;
    _lastLocationData = null;
    _nativeAnnotationLayersReady = false;
    _cameraRevision.dispose();
    unawaited(_disposeTileServer());
  }

  Future<void> _disposeTileServer() async {
    await _tileServer?.close(force: true);
    _tileServer = null;
    final archives = _archives.values.toList(growable: false);
    _archives.clear();
    await Future.wait(archives.map((archive) => archive.close()));
  }

  static double _mercatorX(double longitude) => (longitude + 180) / 360;

  static double _mercatorY(double latitude) {
    final radians = latitude.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    return (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
        2;
  }

  static double _inverseMercatorY(double y) {
    final n = math.pi * (1 - 2 * y);
    return math.atan((math.exp(n) - math.exp(-n)) / 2) * 180 / math.pi;
  }
}

class _MapFrameProjectionRevisionBridge extends StatefulWidget {
  const _MapFrameProjectionRevisionBridge({required this.revision});

  final ValueNotifier<int> revision;

  @override
  State<_MapFrameProjectionRevisionBridge> createState() =>
      _MapFrameProjectionRevisionBridgeState();
}

class _MapFrameProjectionRevisionBridgeState
    extends State<_MapFrameProjectionRevisionBridge> {
  ml.MapCamera? _lastCamera;
  Size? _lastSize;
  bool _notificationScheduled = false;

  @override
  Widget build(BuildContext context) {
    final camera = ml.MapCamera.maybeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (camera != _lastCamera || size != _lastSize) {
          _lastCamera = camera;
          _lastSize = size;
          _scheduleRevision();
        }
        return const SizedBox.expand();
      },
    );
  }

  void _scheduleRevision() {
    if (_notificationScheduled) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (mounted) widget.revision.value++;
    });
  }
}

class _ProvinceHighlight {
  const _ProvinceHighlight({
    required this.rings,
    required this.fillColor,
    required this.borderColor,
  });

  final List<List<LatLng>> rings;
  final Color fillColor;
  final Color borderColor;
}

class _ReferenceStyleSpec {
  const _ReferenceStyleSpec({
    required this.category,
    required this.sourceId,
    required this.layerId,
    required this.color,
    required this.width,
    this.fadeStart,
    this.fadeEnd,
  });

  final String category;
  final String sourceId;
  final String layerId;
  final Color color;
  final double width;
  final double? fadeStart;
  final double? fadeEnd;
}
