import 'package:flutter/foundation.dart';

/// Rendering diagnostics used by profile tests without affecting the UI.
class GisRenderMetrics extends ChangeNotifier {
  GisRenderMetrics({this.enabled = true});

  GisRenderMetrics.disabled() : enabled = false;

  final bool enabled;

  int mapBuildCount = 0;
  int tileCollectionBuildCount = 0;
  int polygonLayerBuildCount = 0;
  int polygonObjectCreationCount = 0;
  int polygonObjectReuseCount = 0;
  int projectedGeometryCacheHitCount = 0;
  int projectedPolygonCount = 0;
  int projectedVertexCount = 0;
  int paintCount = 0;
  int submittedPolygonCount = 0;
  int submittedVertexCount = 0;
  int polygonGenerationCount = 0;
  Duration totalPolygonGenerationDuration = Duration.zero;
  int hitTestCount = 0;
  Duration totalHitTestDuration = Duration.zero;
  int visibleGeometrySampleCount = 0;
  int totalVisiblePolygonCount = 0;
  int totalVisibleVertexCount = 0;
  int maxVisiblePolygonCount = 0;
  int maxVisibleVertexCount = 0;
  Duration totalPaintDuration = Duration.zero;

  void recordVisibleGeometry({
    required int polygonCount,
    required int vertexCount,
  }) {
    if (!enabled) {
      return;
    }
    visibleGeometrySampleCount++;
    totalVisiblePolygonCount += polygonCount;
    totalVisibleVertexCount += vertexCount;
    maxVisiblePolygonCount = maxVisiblePolygonCount < polygonCount
        ? polygonCount
        : maxVisiblePolygonCount;
    maxVisibleVertexCount = maxVisibleVertexCount < vertexCount
        ? vertexCount
        : maxVisibleVertexCount;
  }

  void reset() {
    mapBuildCount = 0;
    tileCollectionBuildCount = 0;
    polygonLayerBuildCount = 0;
    polygonObjectCreationCount = 0;
    polygonObjectReuseCount = 0;
    projectedGeometryCacheHitCount = 0;
    projectedPolygonCount = 0;
    projectedVertexCount = 0;
    paintCount = 0;
    submittedPolygonCount = 0;
    submittedVertexCount = 0;
    polygonGenerationCount = 0;
    totalPolygonGenerationDuration = Duration.zero;
    hitTestCount = 0;
    totalHitTestDuration = Duration.zero;
    visibleGeometrySampleCount = 0;
    totalVisiblePolygonCount = 0;
    totalVisibleVertexCount = 0;
    maxVisiblePolygonCount = 0;
    maxVisibleVertexCount = 0;
    totalPaintDuration = Duration.zero;
    notifyListeners();
  }

  GisRenderMetricsSnapshot snapshot() {
    return GisRenderMetricsSnapshot(
      mapBuildCount: mapBuildCount,
      tileCollectionBuildCount: tileCollectionBuildCount,
      polygonLayerBuildCount: polygonLayerBuildCount,
      polygonObjectCreationCount: polygonObjectCreationCount,
      polygonObjectReuseCount: polygonObjectReuseCount,
      projectedGeometryCacheHitCount: projectedGeometryCacheHitCount,
      projectedPolygonCount: projectedPolygonCount,
      projectedVertexCount: projectedVertexCount,
      paintCount: paintCount,
      submittedPolygonCount: submittedPolygonCount,
      submittedVertexCount: submittedVertexCount,
      polygonGenerationCount: polygonGenerationCount,
      totalPolygonGenerationDuration: totalPolygonGenerationDuration,
      hitTestCount: hitTestCount,
      totalHitTestDuration: totalHitTestDuration,
      visibleGeometrySampleCount: visibleGeometrySampleCount,
      totalVisiblePolygonCount: totalVisiblePolygonCount,
      totalVisibleVertexCount: totalVisibleVertexCount,
      maxVisiblePolygonCount: maxVisiblePolygonCount,
      maxVisibleVertexCount: maxVisibleVertexCount,
      totalPaintDuration: totalPaintDuration,
    );
  }
}

class GisRenderMetricsSnapshot {
  const GisRenderMetricsSnapshot({
    required this.mapBuildCount,
    required this.tileCollectionBuildCount,
    required this.polygonLayerBuildCount,
    required this.polygonObjectCreationCount,
    required this.polygonObjectReuseCount,
    required this.projectedGeometryCacheHitCount,
    required this.projectedPolygonCount,
    required this.projectedVertexCount,
    required this.paintCount,
    required this.submittedPolygonCount,
    required this.submittedVertexCount,
    required this.polygonGenerationCount,
    required this.totalPolygonGenerationDuration,
    required this.hitTestCount,
    required this.totalHitTestDuration,
    required this.visibleGeometrySampleCount,
    required this.totalVisiblePolygonCount,
    required this.totalVisibleVertexCount,
    required this.maxVisiblePolygonCount,
    required this.maxVisibleVertexCount,
    required this.totalPaintDuration,
  });

  final int mapBuildCount;
  final int tileCollectionBuildCount;
  final int polygonLayerBuildCount;
  final int polygonObjectCreationCount;
  final int polygonObjectReuseCount;
  final int projectedGeometryCacheHitCount;
  final int projectedPolygonCount;
  final int projectedVertexCount;
  final int paintCount;
  final int submittedPolygonCount;
  final int submittedVertexCount;
  final int polygonGenerationCount;
  final Duration totalPolygonGenerationDuration;
  final int hitTestCount;
  final Duration totalHitTestDuration;
  final int visibleGeometrySampleCount;
  final int totalVisiblePolygonCount;
  final int totalVisibleVertexCount;
  final int maxVisiblePolygonCount;
  final int maxVisibleVertexCount;
  final Duration totalPaintDuration;
}
