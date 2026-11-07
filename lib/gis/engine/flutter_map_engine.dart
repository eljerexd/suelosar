import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../gis_feature.dart';
import '../gis_layer.dart';
import '../native_map_source.dart';
import '../../models/saved_measurement.dart';
import 'soil_map_engine.dart';

/// [SoilMapEngine] implementation backed by `flutter_map`.
///
/// This is the default, active engine implementation on every platform
/// (Windows, and Android/iOS unless a [SoilMapEngine] override is injected
/// for evaluation — see [MapLibreEngine]). It owns the `flutter_map`
/// [MapController] and encapsulates the direct construction of
/// [FlutterMap]/[MapOptions] so the rest of the GIS screen no longer needs to
/// import or reference `flutter_map` types for camera/navigation purposes.
///
/// [children] passed to [buildMapSurface] remain `flutter_map`-specific
/// layer widgets (`PolygonLayer`, `MarkerLayer`, `CircleLayer`, etc.) — this
/// is a deliberate, documented remaining coupling. Soil-polygon
/// loading/selection/hit-testing/visibility are intentionally no-ops here:
/// [GisMapScreen] already owns that rendering directly through its
/// `children` widgets and its own `_findFeatureAt`, unchanged since before
/// this abstraction existed.
class FlutterMapEngine implements SoilMapEngine {
  FlutterMapEngine() : _controller = MapController();

  final MapController _controller;
  final ValueNotifier<int> _cameraRevision = ValueNotifier(0);
  double _minZoom = 0;
  double _maxZoom = 24;

  @override
  Listenable get cameraChanges => _cameraRevision;

  @override
  bool get rendersSoilPolygonsInternally => false;

  /// Escape hatch for code that still needs the raw `flutter_map`
  /// [MapController]/[MapCamera] — today, only the soil-polygon tile
  /// viewport calculation (`_scheduleTileLoad`/`_loadVisibleTiles` in
  /// [GisMapScreen]), which is rendering logic explicitly out of scope for
  /// this abstraction. Not part of [SoilMapEngine].
  MapController get controller => _controller;

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
    return FlutterMap(
      key: key,
      mapController: _controller,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        minZoom: minZoom,
        maxZoom: maxZoom,
        backgroundColor: backgroundColor,
        interactionOptions: InteractionOptions(
          flags: gesturesEnabled
              ? InteractiveFlag.all
              : InteractiveFlag.all &
                    ~InteractiveFlag.drag &
                    ~InteractiveFlag.flingAnimation &
                    ~InteractiveFlag.pinchMove,
        ),
        onMapReady: onReady,
        onPositionChanged: (camera, hasGesture) {
          _cameraRevision.value++;
          onPositionChanged(_toState(camera), hasGesture: hasGesture);
        },
        onMapEvent: (event) {
          // Rotation (pure `.rotate()` calls and two-finger rotate
          // gestures) does not trigger `onPositionChanged` in flutter_map —
          // only `onMapEvent`. Forwarding it through the same callback keeps
          // viewport-dependent overlays (compass) in sync during rotation,
          // exactly as the screen did before this abstraction existed.
          _cameraRevision.value++;
          onPositionChanged(
            _toState(event.camera),
            hasGesture: event.source != MapEventSource.mapController,
          );
        },
        onTap: onTap == null
            ? null
            : (tapPosition, point) {
                onTap(
                  SoilMapTapDetails(
                    screenOffset: tapPosition.relative ?? tapPosition.global,
                    point: point,
                  ),
                );
              },
      ),
      children: [...children, ...mapFrameChildren],
    );
  }

  @override
  SoilMapCameraState get camera => _toState(_controller.camera);

  @override
  void move(LatLng center, double zoom) => _controller.move(center, zoom);

  @override
  void zoomAtScreenPoint(Offset screenPoint, double scrollDeltaY) {
    if (scrollDeltaY == 0 || !scrollDeltaY.isFinite) return;
    final camera = _controller.camera;
    final zoom = (camera.zoom - scrollDeltaY * 0.005).clamp(_minZoom, _maxZoom);
    if (zoom == camera.zoom) return;
    _controller.move(camera.focusedZoomCenter(screenPoint, zoom), zoom);
  }

  @override
  void rotate(double degrees) => _controller.rotate(degrees);

  @override
  SoilMapCameraState fitBounds(
    List<LatLng> points, {
    EdgeInsets padding = EdgeInsets.zero,
    double? maxZoom,
  }) {
    final fitted = CameraFit.coordinates(
      coordinates: points,
      padding: padding,
      maxZoom: maxZoom,
    ).fit(_controller.camera);
    return _toState(fitted);
  }

  @override
  Offset? latLngToScreenOffset(LatLng point) {
    return _controller.camera.latLngToScreenOffset(point);
  }

  @override
  LatLng? screenOffsetToLatLng(Offset offset) {
    return _controller.camera.screenOffsetToLatLng(offset);
  }

  @override
  void dispose() {
    // MapController does not require explicit disposal in flutter_map's
    // current API — mirrors the screen's previous behavior, which never
    // disposed it either.
    _cameraRevision.dispose();
  }

  @override
  Future<void> loadSoilPolygonsLayer({
    required GisArchiveInfo archiveInfo,
    required String layerName,
    required Color normalFillColor,
    required Color selectedFillColor,
    required List<GisNativeMapSource> sources,
  }) async {
    // No-op: GisMapScreen renders soil polygons via its own tile pipeline
    // and `children` widgets, unchanged since before this engine existed.
  }

  @override
  void setSelectedSoilFeature(String? featureId, {GisFeature? feature}) {
    // No-op: selection highlighting is driven directly by GisMapScreen's
    // `children` widgets.
  }

  @override
  Future<GisFeature?> hitTestSoilFeature(Offset screenOffset) async => null;

  @override
  void setSoilPolygonsVisible(bool visible) {
    // No-op: GisMapScreen conditionally builds/omits its polygon `children`
    // widget instead.
  }

  @override
  void setReferenceBasemapVisible(bool visible) {
    // No-op: same reasoning as setSoilPolygonsVisible.
  }

  @override
  Future<void> loadReferenceBasemap({required List<String> assetPaths}) async {
    // No-op: rendered via OfflineReferenceMapLayer as a `children` widget.
  }

  @override
  void setPersonalMarkers(
    List<SoilMapMarkerPin> markers, {
    required ValueChanged<String> onMarkerTap,
  }) {
    // No-op: rendered via a `children` MarkerLayer widget.
  }

  @override
  void setCurrentLocationMarker({
    LatLng? point,
    double? accuracyMeters,
    required bool showAccuracyCircle,
  }) {
    // No-op: rendered via a `children` _CurrentLocationLayer widget.
  }

  @override
  void setSavedMeasurementGeometry({
    required List<SavedMeasurement> measurements,
    String? highlightedId,
    String? hoveredId,
    ValueChanged<String?>? onHoverChanged,
  }) {
    // No-op: rendered via a `children` _SavedMeasurementsLayer widget.
  }

  @override
  void setMeasurementGeometry({
    required List<LatLng> distancePoints,
    required List<LatLng> areaPoints,
    required Color color,
    List<SoilMapMeasurementMarker> markers = const [],
  }) {
    // No-op: rendered via a `children` _MeasurementLayer widget, whose own
    // _AreaVertexHandle gesture handling is unchanged by this engine layer.
  }

  @override
  void setProvinceBoundaryHighlight({
    required String coverageId,
    required List<List<LatLng>>? rings,
    required Color fillColor,
    required Color borderColor,
  }) {
    // No-op: FlutterMapEngine draws the same rings in its screen overlay.
  }

  SoilMapCameraState _toState(MapCamera camera) {
    SoilMapVisibleBounds? visibleBounds;
    final size = camera.nonRotatedSize;
    final center = camera.center;
    if (size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0 &&
        center.latitude.isFinite &&
        center.longitude.isFinite &&
        camera.zoom.isFinite &&
        camera.rotation.isFinite) {
      try {
        final bounds = camera.visibleBounds;
        if (bounds.west.isFinite &&
            bounds.south.isFinite &&
            bounds.east.isFinite &&
            bounds.north.isFinite) {
          visibleBounds = SoilMapVisibleBounds(
            west: bounds.west,
            south: bounds.south,
            east: bounds.east,
            north: bounds.north,
          );
        }
      } on AssertionError {
        // flutter_map can expose an invalid camera for the first layout frame.
      }
    }
    return SoilMapCameraState(
      center: center,
      zoom: camera.zoom,
      rotation: camera.rotation,
      visibleBounds: visibleBounds,
    );
  }
}
