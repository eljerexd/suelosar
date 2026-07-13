import 'dart:async';

import 'package:flutter/foundation.dart';

/// Temporary debug-only telemetry for diagnosing GIS pipeline stalls.
class GisPipelineDebugCounters {
  GisPipelineDebugCounters._();

  static final GisPipelineDebugCounters instance = GisPipelineDebugCounters._();

  final Set<int> _activeViewportGenerations = <int>{};
  final Set<int> _cancelledViewportGenerations = <int>{};
  Timer? _logTimer;
  int _activeTileTasks = 0;
  int _activeIsolateTasks = 0;
  int _queuedTileRequests = 0;
  int _decodedSinceLastReport = 0;
  int _cacheHits = 0;
  int _cacheMisses = 0;
  int _visibleTileCount = 0;
  int _prefetchTileCount = 0;
  int _maxActiveViewportGenerations = 0;

  @visibleForTesting
  int get activeViewportCount => _activeViewportGenerations.length;

  @visibleForTesting
  int get maxActiveViewportCount => _maxActiveViewportGenerations;

  @visibleForTesting
  void resetViewportPeak() {
    _maxActiveViewportGenerations = _activeViewportGenerations.length;
  }

  void startLogging() {
    if (!kDebugMode || _logTimer != null) return;
    _logTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      debugPrint(
        '[GIS pipeline] viewportActive=${_activeViewportGenerations.length} '
        'tileTasks=$_activeTileTasks isolates=$_activeIsolateTasks '
        'queued=$_queuedTileRequests decoded/s=$_decodedSinceLastReport '
        'cacheHits=$_cacheHits cacheMisses=$_cacheMisses '
        'visible=$_visibleTileCount prefetch=$_prefetchTileCount',
      );
      _decodedSinceLastReport = 0;
    });
  }

  void stopLogging() {
    if (!kDebugMode) return;
    _logTimer?.cancel();
    _logTimer = null;
  }

  void viewportStarted({
    required int generation,
    required int visibleTileCount,
    required int prefetchTileCount,
  }) {
    if (!kDebugMode) return;
    for (final activeGeneration in _activeViewportGenerations) {
      if (activeGeneration == generation ||
          !_cancelledViewportGenerations.add(activeGeneration)) {
        continue;
      }
      debugPrint(
        '[GIS viewport] generation=$activeGeneration cancelledBy=$generation',
      );
    }
    _activeViewportGenerations.add(generation);
    if (_activeViewportGenerations.length > _maxActiveViewportGenerations) {
      _maxActiveViewportGenerations = _activeViewportGenerations.length;
    }
    _visibleTileCount = visibleTileCount;
    _prefetchTileCount = prefetchTileCount;
    debugPrint(
      '[GIS viewport] generation=$generation started '
      'visible=$visibleTileCount prefetch=$prefetchTileCount',
    );
  }

  void viewportFinished(int generation, {required String outcome}) {
    if (!kDebugMode) return;
    _activeViewportGenerations.remove(generation);
    _cancelledViewportGenerations.remove(generation);
    debugPrint(
      '[GIS viewport] generation=$generation $outcome '
      'active=${_activeViewportGenerations.length}',
    );
  }

  void cacheHit() {
    if (kDebugMode) _cacheHits++;
  }

  void cacheMiss() {
    if (kDebugMode) _cacheMisses++;
  }

  void tileTaskStarted() {
    if (kDebugMode) _activeTileTasks++;
  }

  void tileTaskFinished() {
    if (kDebugMode) _activeTileTasks--;
  }

  void isolateStarted() {
    if (kDebugMode) _activeIsolateTasks++;
  }

  void isolateFinished() {
    if (kDebugMode) _activeIsolateTasks--;
  }

  void tileDecoded() {
    if (kDebugMode) _decodedSinceLastReport++;
  }

  void queuedTileRequestsChanged(int value) {
    if (kDebugMode) _queuedTileRequests = value;
  }
}
