import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../gis_feature.dart';
import '../gis_layer.dart';

/// Snapshot of the map camera (center, zoom, rotation) exposed by a
/// [SoilMapEngine], independent of the concrete rendering engine.
@immutable
class SoilMapCameraState {
  const SoilMapCameraState({
    required this.center,
    required this.zoom,
    required this.rotation,
  });

  final LatLng center;
  final double zoom;
  final double rotation;

  @override
  bool operator ==(Object other) {
    return other is SoilMapCameraState &&
        other.center.latitude == center.latitude &&
        other.center.longitude == center.longitude &&
        other.zoom == zoom &&
        other.rotation == rotation;
  }

  @override
  int get hashCode =>
      Object.hash(center.latitude, center.longitude, zoom, rotation);
}

/// Details of a tap on the map surface, independent of the concrete
/// rendering engine.
@immutable
class SoilMapTapDetails {
  const SoilMapTapDetails({required this.screenOffset, required this.point});

  /// Tap position local to the map surface.
  final Offset screenOffset;

  /// Geographic coordinate under [screenOffset].
  final LatLng point;
}

typedef SoilMapReadyCallback = void Function();

typedef SoilMapPositionChangedCallback =
    void Function(SoilMapCameraState camera, {required bool hasGesture});

typedef SoilMapTapCallback = void Function(SoilMapTapDetails details);

/// A personal-marker pin, independent of the concrete rendering engine.
@immutable
class SoilMapMarkerPin {
  const SoilMapMarkerPin({
    required this.id,
    required this.point,
    required this.icon,
  });

  final String id;
  final LatLng point;

  /// The category icon `GisMapScreen` already resolves via
  /// `personalMarkerCategoryIcon` — passed through so engines that render
  /// markers independently of a `children` widget (MapLibreEngine) can
  /// match the personal-marker icon/category visual FlutterMapEngine
  /// already shows via its own `Icon(personalMarkerCategoryIcon(...))`.
  /// FlutterMapEngine itself ignores this (its markers come from
  /// `children`, unaffected by this field).
  final IconData icon;
}

/// Abstraction over the concrete map-rendering engine used by
/// [GisMapScreen].
///
/// Covers camera/navigation (Etapa 2), soil-polygon rendering/selection, and
/// personal markers / GPS visual / distance & area measurement rendering
/// (Etapa 3 continuation) — the capabilities needed for functional parity
/// between [FlutterMapEngine] and [MapLibreEngine]. `flutter_map`-specific
/// layer widgets are still accepted via [children] for FlutterMapEngine;
/// MapLibreEngine ignores them (it draws everything through the methods
/// below instead, since MapLibre has no per-frame layer-widget model).
///
/// Not covered: interactive measurement editing (dragging an existing
/// vertex, or inserting a new point mid-edge instead of at the end) needs
/// synchronous screen<->geo projection, which MapLibre's plugin only
/// exposes asynchronously. See the Etapa 3 continuation report for the full
/// analysis — [latLngToScreenOffset]/[screenOffsetToLatLng] were kept
/// synchronous rather than reshaping them (and every FlutterMapEngine
/// call-site) around MapLibre's async API.
abstract interface class SoilMapEngine {
  /// Builds the widget that hosts the map surface plus everything composed
  /// on top of it via [children].
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
  });

  /// Current camera snapshot. Only meaningful after [SoilMapReadyCallback]
  /// has fired.
  SoilMapCameraState get camera;

  /// Moves the camera immediately (no animation) to [center]/[zoom].
  void move(LatLng center, double zoom);

  /// Rotates the camera to an absolute [degrees] heading (0 = north up).
  void rotate(double degrees);

  /// Computes the center/zoom that fits all [points] within the viewport.
  /// Does not move the camera — callers pass the result to [move], the same
  /// way the screen already animates camera transitions itself.
  SoilMapCameraState fitBounds(
    List<LatLng> points, {
    EdgeInsets padding = EdgeInsets.zero,
    double? maxZoom,
  });

  /// Converts a geographic point to a screen offset local to the map
  /// surface. Returns null if the point cannot be projected.
  Offset? latLngToScreenOffset(LatLng point);

  /// Converts a screen offset local to the map surface to a geographic
  /// point. Returns null if the offset cannot be projected.
  LatLng? screenOffsetToLatLng(Offset offset);

  /// Loads (or reloads) the soil-polygon layer for engines that render it
  /// internally from the real PMTiles archive (MapLibre). No-op for engines
  /// that instead receive polygons as `children` widgets (FlutterMapEngine),
  /// where [GisMapScreen]'s existing tile pipeline already owns rendering.
  ///
  /// [normalFillColor]/[selectedFillColor] mirror
  /// `_GisPolygonStyle.fromColorScheme` (`gis_map_screen.dart`) so the style
  /// reflects SuelosAR's actual theme instead of a hardcoded approximation.
  Future<void> loadSoilPolygonsLayer({
    required GisArchiveInfo archiveInfo,
    required String layerName,
    required Color normalFillColor,
    required Color selectedFillColor,
  });

  /// Highlights [featureId] in the soil-polygon layer for engines that draw
  /// it internally. No-op for FlutterMapEngine, whose selection highlight is
  /// driven directly by [GisMapScreen] through its `children` widgets.
  void setSelectedSoilFeature(String? featureId);

  /// Resolves the soil feature under [screenOffset], for engines that own
  /// their rendering and hit-testing internally (MapLibre's
  /// `queryRenderedFeatures`). Always returns null for FlutterMapEngine —
  /// [GisMapScreen] keeps using its existing geometry-based
  /// `_findFeatureAt(LatLng)` for that engine instead.
  Future<GisFeature?> hitTestSoilFeature(Offset screenOffset);

  /// Shows/hides the soil-polygon layer for engines that render it
  /// internally. No-op for FlutterMapEngine, which already conditionally
  /// builds/omits its polygon `children` widget.
  void setSoilPolygonsVisible(bool visible);

  /// Shows/hides the offline reference basemap for engines that render it
  /// internally. No-op for FlutterMapEngine, same reasoning as above.
  void setReferenceBasemapVisible(bool visible);

  /// Loads the offline agronomic reference basemap (roads, rivers,
  /// boundaries, city labels) for engines that render it internally.
  /// No-op for FlutterMapEngine, which already renders it via
  /// `OfflineReferenceMapLayer` as a `children` widget.
  Future<void> loadReferenceBasemap();

  /// Replaces the set of rendered personal-marker pins. [onMarkerTap] is
  /// invoked with a pin's [SoilMapMarkerPin.id] when tapped. No-op for
  /// FlutterMapEngine, which renders markers via its `children` widgets.
  void setPersonalMarkers(
    List<SoilMapMarkerPin> markers, {
    required ValueChanged<String> onMarkerTap,
  });

  /// Shows/updates/hides the current-location marker. Pass `point: null` to
  /// hide it. No-op for FlutterMapEngine, which renders GPS via its
  /// `children` widgets (`_CurrentLocationLayer`).
  void setCurrentLocationMarker({
    LatLng? point,
    double? accuracyMeters,
    required bool showAccuracyCircle,
  });

  /// Replaces the rendered in-progress measurement geometry — at most one of
  /// [distancePoints]/[areaPoints] is expected to be non-empty at a time,
  /// mirroring `_MeasurementMode`. Vertices are rendered numbered, matching
  /// `_MeasurementLayer._buildEditableVertexMarker`.
  ///
  /// [onVertexTap] fires with the vertex index and the tap's screen offset
  /// (for positioning the same `showMenu` delete/cancel popup
  /// FlutterMapEngine already uses — see `_showVertexMenuAt` in
  /// `GisMapScreen`). [onVertexDragStart]/[onVertexDragUpdate]/
  /// [onVertexDragEnd] mirror `_startAreaVertexDrag`/`_moveAreaVertex`/
  /// `_endAreaVertexDrag` — MapLibre delivers the dragged LatLng directly via
  /// its native draggable-annotation API, so no screen<->geo projection is
  /// involved (see the Etapa 3 measurement architecture note).
  ///
  /// No-op for FlutterMapEngine, which renders measurements via
  /// `_MeasurementLayer` as a `children` widget and ignores every callback
  /// here (its own gesture handling in `_AreaVertexHandle` is unchanged).
  ///
  /// [draggedVertexIndex] is the index currently being dragged (matching
  /// `GisMapScreen._draggedAreaVertexIndex`), or null when no vertex is
  /// being dragged — mirrors `_AreaVertexHandle`'s `isDragged` visual state
  /// (44x44, error-colored) for engines that render vertices themselves.
  /// No-op for FlutterMapEngine, whose `_AreaVertexHandle` already reads
  /// `_draggedAreaVertexIndex` directly.
  void setMeasurementGeometry({
    required List<LatLng> distancePoints,
    required List<LatLng> areaPoints,
    required Color color,
    required void Function(int index, Offset screenPosition) onVertexTap,
    required void Function(int index) onVertexDragStart,
    required void Function(int index, LatLng newPoint) onVertexDragUpdate,
    required void Function(int index) onVertexDragEnd,
    int? draggedVertexIndex,
  });

  void dispose();
}
