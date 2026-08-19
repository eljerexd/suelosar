import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../gis_feature.dart';
import '../gis_layer.dart';
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
    required SoilMapReadyCallback onReady,
    required SoilMapPositionChangedCallback onPositionChanged,
    SoilMapTapCallback? onTap,
    required List<Widget> children,
  }) {
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
          onPositionChanged(_toState(camera), hasGesture: hasGesture);
        },
        onMapEvent: (event) {
          // Rotation (pure `.rotate()` calls and two-finger rotate
          // gestures) does not trigger `onPositionChanged` in flutter_map —
          // only `onMapEvent`. Forwarding it through the same callback keeps
          // viewport-dependent overlays (compass) in sync during rotation,
          // exactly as the screen did before this abstraction existed.
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
      children: children,
    );
  }

  @override
  SoilMapCameraState get camera => _toState(_controller.camera);

  @override
  void move(LatLng center, double zoom) => _controller.move(center, zoom);

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
  }

  @override
  Future<void> loadSoilPolygonsLayer({
    required GisArchiveInfo archiveInfo,
    required String layerName,
    required Color normalFillColor,
    required Color selectedFillColor,
  }) async {
    // No-op: GisMapScreen renders soil polygons via its own tile pipeline
    // and `children` widgets, unchanged since before this engine existed.
  }

  @override
  void setSelectedSoilFeature(String? featureId) {
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
  Future<void> loadReferenceBasemap() async {
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
  void setMeasurementGeometry({
    required List<LatLng> distancePoints,
    required List<LatLng> areaPoints,
    required Color color,
    required void Function(int index, Offset screenPosition) onVertexTap,
    required void Function(int index) onVertexDragStart,
    required void Function(int index, LatLng newPoint) onVertexDragUpdate,
    required void Function(int index) onVertexDragEnd,
  }) {
    // No-op: rendered via a `children` _MeasurementLayer widget, whose own
    // _AreaVertexHandle gesture handling is unchanged by this engine layer.
  }

  SoilMapCameraState _toState(MapCamera camera) {
    return SoilMapCameraState(
      center: camera.center,
      zoom: camera.zoom,
      rotation: camera.rotation,
    );
  }
}
