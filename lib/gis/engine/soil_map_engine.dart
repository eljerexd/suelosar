import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../gis_feature.dart';
import '../gis_layer.dart';
import '../native_map_source.dart';
import '../../models/saved_measurement.dart';

/// Snapshot of the map camera (center, zoom, rotation) exposed by a
/// [SoilMapEngine], independent of the concrete rendering engine.
@immutable
class SoilMapCameraState {
  const SoilMapCameraState({
    required this.center,
    required this.zoom,
    required this.rotation,
    this.visibleBounds,
  });

  final LatLng center;
  final double zoom;
  final double rotation;
  final SoilMapVisibleBounds? visibleBounds;

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

@immutable
class SoilMapVisibleBounds {
  const SoilMapVisibleBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  static SoilMapVisibleBounds? fromCorners(Iterable<LatLng> corners) {
    final points = corners.toList(growable: false);
    if (points.isEmpty ||
        points.any(
          (point) => !point.latitude.isFinite || !point.longitude.isFinite,
        )) {
      return null;
    }
    return SoilMapVisibleBounds(
      west: points.map((point) => point.longitude).reduce(math.min),
      south: points.map((point) => point.latitude).reduce(math.min),
      east: points.map((point) => point.longitude).reduce(math.max),
      north: points.map((point) => point.latitude).reduce(math.max),
    );
  }

  final double west;
  final double south;
  final double east;
  final double north;
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

typedef SoilMapPositionChangedCallback = void Function(
  SoilMapCameraState camera, {
  required bool hasGesture,
});

typedef SoilMapTapCallback = void Function(SoilMapTapDetails details);

/// A personal-marker pin, independent of the concrete rendering engine.
@immutable
class SoilMapMarkerPin {
  const SoilMapMarkerPin({
    required this.id,
    required this.point,
    required this.icon,
    this.categoryId = 'other',
    this.properties = const {},
  });

  final String id;
  final LatLng point;

  /// The category icon `GisMapScreen` already resolves via
  /// `personalMarkerCategoryIcon`. MapLibre registers it as a local style
  /// image; FlutterMapEngine renders it from the existing child layer.
  final IconData icon;
  final String categoryId;
  final Map<String, Object?> properties;
}

/// A Flutter interaction widget projected at a geographic measurement point
/// by a map engine. Measurement lines and polygons remain engine-rendered.
@immutable
class SoilMapMeasurementMarker {
  const SoilMapMeasurementMarker({
    required this.point,
    required this.size,
    required this.child,
    this.label = '',
    this.radius = 15,
    this.fillColor = const Color(0xFF0000FF),
    this.textColor = const Color(0xFFFFFFFF),
    this.strokeColor = const Color(0xFFFFFFFF),
    this.strokeWidth = 3,
    this.alignment = Alignment.center,
    this.useFlutterOverlay = false,
  });

  final LatLng point;
  final Size size;
  final Widget child;
  final String label;
  final double radius;
  final Color fillColor;
  final Color textColor;
  final Color strokeColor;
  final double strokeWidth;
  final Alignment alignment;
  final bool useFlutterOverlay;
}

/// Abstraction over the concrete map-rendering engine used by
/// [GisMapScreen].
///
/// Covers camera/navigation and native soil-polygon rendering/selection.
/// [FlutterMapEngine] renders the screen's map children directly. The current
/// [MapLibreEngine] renders geographic data natively and hosts ordinary
/// Flutter UI overlays above its single native map viewport.
///
/// MapLibre measurement markers use the engine's synchronous projection
/// methods for screen-position interactions; calculations and state remain
/// owned by [GisMapScreen].
abstract interface class SoilMapEngine {
  /// Whether soil polygons are drawn by the engine instead of Flutter
  /// children. The screen still loads decoded tiles for search and fallback.
  bool get rendersSoilPolygonsInternally;

  /// Notifies screen-space overlays that the engine camera has moved or the
  /// viewport has changed. Geographic native layers do not need this signal.
  Listenable get cameraChanges;

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
    required bool annotationGesturesEnabled,
    required SoilMapReadyCallback onReady,
    required SoilMapPositionChangedCallback onPositionChanged,
    SoilMapTapCallback? onTap,
    required List<Widget> children,
    List<Widget> mapFrameChildren = const [],
  });

  /// Current camera snapshot. Only meaningful after [SoilMapReadyCallback]
  /// has fired.
  SoilMapCameraState get camera;

  /// Moves the camera immediately (no animation) to [center]/[zoom].
  void move(LatLng center, double zoom);

  /// Applies a mouse-wheel zoom around [screenPoint], local to the map
  /// surface. Used by interactive measurement overlays above the map.
  void zoomAtScreenPoint(Offset screenPoint, double scrollDeltaY);

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
    required List<GisNativeMapSource> sources,
  });

  /// Highlights [featureId] in the soil-polygon layer for engines that draw
  /// it internally. No-op for FlutterMapEngine, whose selection highlight is
  /// driven directly by [GisMapScreen] through its `children` widgets.
  void setSelectedSoilFeature(String? featureId, {GisFeature? feature});

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

  /// Loads the offline agronomic reference basemap for engines that own its
  /// rendering. [assetPaths] are the EPSG:4326 reference-map datasets selected
  /// by the active province coverages.
  Future<void> loadReferenceBasemap({required List<String> assetPaths});

  /// Replaces personal-marker pins for engines that render them as geographic
  /// annotations. [onMarkerTap] receives a pin's [SoilMapMarkerPin.id].
  void setPersonalMarkers(
    List<SoilMapMarkerPin> markers, {
    required ValueChanged<String> onMarkerTap,
  });

  /// Shows, updates, or hides a current-location marker for engines that
  /// render it as a geographic annotation. Pass `point: null` to hide it.
  void setCurrentLocationMarker({
    LatLng? point,
    double? accuracyMeters,
    required bool showAccuracyCircle,
  });

  /// Replaces the visible saved-measurement geometry rendered by engines
  /// that own native geographic layers. FlutterMapEngine keeps rendering the
  /// corresponding children passed to [buildMapSurface].
  void setSavedMeasurementGeometry({
    required List<SavedMeasurement> measurements,
    String? highlightedId,
    String? hoveredId,
    ValueChanged<String?>? onHoverChanged,
  });

  /// Replaces the rendered in-progress measurement geometry — at most one of
  /// [distancePoints]/[areaPoints] is expected to be non-empty at a time,
  /// mirroring `_MeasurementMode`. Vertices are rendered numbered, matching
  /// `_MeasurementLayer._buildEditableVertexMarker`.
  ///
  /// [markers] provide measurement vertex styling and Flutter hit targets.
  /// Native engines render the marker features together with active geometry
  /// from one GeoJSON snapshot; the child is used only for pointer handling.
  ///
  /// No-op for FlutterMapEngine, which renders geometry and marker widgets in
  /// `_MeasurementLayer` as before.
  void setMeasurementGeometry({
    required List<LatLng> distancePoints,
    required List<LatLng> areaPoints,
    required Color color,
    List<SoilMapMeasurementMarker> markers = const [],
  });

  /// Replaces an on-demand province highlight with one immutable geographic
  /// snapshot shared by its fill and boundary rendering.
  void setProvinceBoundaryHighlight({
    required String coverageId,
    required List<List<LatLng>>? rings,
    required Color fillColor,
    required Color borderColor,
  });

  void dispose();
}
