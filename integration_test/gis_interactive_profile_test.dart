import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profiles a real medium-zoom pan and zoom session', (
    tester,
  ) async {
    final metrics = GisRenderMetrics();
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: AssetPaths.gisPmTiles,
      versionAssetPath: AssetPaths.gisPmTilesVersion,
      layerName: AssetPaths.gisLayerName,
    );
    addTearDown(metrics.dispose);
    addTearDown(repository.close);
    await repository.initialize();
    await repository.loadTile(const GisTileCoordinates(zoom: 6, x: 21, y: 38));

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: repository, renderMetrics: metrics),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _waitForTiles(tester, metrics);

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final controller = map.mapController!;
    controller.move(const LatLng(-35.85, -60.55), 9);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await _waitForTiles(tester, metrics);

    final serviceInfo = await developer.Service.getInfo();
    final webSocketUri = serviceInfo.serverWebSocketUri;
    expect(webSocketUri, isNotNull);
    final service = await vmServiceConnectUri(webSocketUri.toString());
    addTearDown(service.dispose);
    final vm = await service.getVM();
    final isolate = vm.isolates!.firstWhere(
      (candidate) => candidate.name == 'main',
      orElse: () => vm.isolates!.first,
    );
    final isolateId = isolate.id!;

    final state = tester.state(find.byType(GisMapScreen)) as dynamic;

    final rapidPan = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () => _continuousPan(tester),
    );
    final sustainedPan = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () => _sustainedPan(tester),
    );
    final zoomIn = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () async {
        final center = tester.getCenter(find.byType(FlutterMap));
        await _pinch(tester, center, outward: true);
      },
    );
    final zoomOut = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () async {
        final center = tester.getCenter(find.byType(FlutterMap));
        await _pinch(tester, center, outward: false);
      },
    );
    final panAndZoom = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () => _panAndPinch(tester),
    );
    final polygonSelection = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () async {
        final currentMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final point = currentMap.mapController!.camera.center;
        final offset = tester.getCenter(find.byType(FlutterMap));
        currentMap.options.onTap!(TapPosition(offset, offset), point);
        await tester.pump();
      },
    );
    final polygonDeselection = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () async {
        final currentMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
        currentMap.options.onTap!(
          const TapPosition(Offset.zero, Offset.zero),
          const LatLng(0, 0),
        );
        await tester.pump();
      },
    );
    final layerToggle = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () => _toggleSoilLayer(tester),
    );
    final mouseWheel = await _profilePhase(
      tester: tester,
      metrics: metrics,
      service: service,
      isolateId: isolateId,
      repository: repository,
      screenState: state,
      action: () => _desktopMouseWheelZoom(tester),
    );

    final report = <String, Object?>{
      'device': 'windows',
      'rapid_pan': rapidPan,
      'sustained_pan': sustainedPan,
      'zoom_in': zoomIn,
      'zoom_out': zoomOut,
      'pan_and_zoom': panAndZoom,
      'polygon_selection': polygonSelection,
      'polygon_deselection': polygonDeselection,
      'layer_toggle': layerToggle,
      'desktop_mouse_wheel': mouseWheel,
    };
    binding.reportData = report;
    debugPrint('GIS_INTERACTIVE_PROFILE ${jsonEncode(report)}');

    expect((rapidPan['frames'] as int), greaterThan(20));
    expect((sustainedPan['frames'] as int), greaterThan(100));
    expect((zoomIn['frames'] as int), greaterThan(10));
    expect((zoomOut['frames'] as int), greaterThan(10));
  });
}

Future<Map<String, Object?>> _profilePhase({
  required WidgetTester tester,
  required GisRenderMetrics metrics,
  required VmService service,
  required String isolateId,
  required PmTilesGisRepository repository,
  required dynamic screenState,
  required Future<void> Function() action,
}) async {
  final availableStreams =
      (await service.getVMTimelineFlags()).availableStreams ?? const <String>[];
  final requestedStreams = <String>[
    for (final stream in const ['Dart', 'Embedder', 'GC', 'Isolate', 'VM'])
      if (availableStreams.contains(stream)) stream,
  ];
  await service.setVMTimelineFlags(requestedStreams);
  await service.clearVMTimeline();
  await service.getAllocationProfile(isolateId, reset: true, gc: true);
  final memoryBefore = await service.getMemoryUsage(isolateId);
  final cacheBefore = repository.cacheMetrics;
  final startMicros = (await service.getVMTimelineMicros()).timestamp!;

  metrics.reset();
  final timings = <FrameTiming>[];
  void collectTimings(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collectTimings);
  final wall = Stopwatch()..start();
  await action();
  wall.stop();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 350)),
  );
  await tester.pump();
  SchedulerBinding.instance.removeTimingsCallback(collectTimings);

  final endMicros = (await service.getVMTimelineMicros()).timestamp!;
  final extentMicros = math.max(1, endMicros - startMicros);
  final cpu = await service.getCpuSamples(isolateId, startMicros, extentMicros);
  final timeline = await service.getVMTimeline(
    timeOriginMicros: startMicros,
    timeExtentMicros: extentMicros,
  );
  final allocations = await service.getAllocationProfile(isolateId);
  final memoryAfter = await service.getMemoryUsage(isolateId);
  final cacheAfter = repository.cacheMetrics;
  final snapshot = metrics.snapshot();

  return <String, Object?>{
    ..._frameSummary(timings, wall.elapsed),
    'cpu_us': _cpuSummary(cpu),
    'pmtiles_read_wall_us': _timelineDuration(timeline, 'SuelosAR.PMTilesRead'),
    'mvt_decode_cpu_us': _timelineDuration(timeline, 'SuelosAR.MVTDecode'),
    'timeline': _timelineSummary(timeline),
    'polygon_generation_cpu_us':
        snapshot.totalPolygonGenerationDuration.inMicroseconds,
    'polygon_paint_cpu_us': snapshot.totalPaintDuration.inMicroseconds,
    'hit_test_cpu_us': snapshot.totalHitTestDuration.inMicroseconds,
    'widget_rebuilds': <String, int>{
      'map': snapshot.mapBuildCount,
      'tile_collection': snapshot.tileCollectionBuildCount,
      'polygon_layer': snapshot.polygonLayerBuildCount,
    },
    'paint': <String, int>{
      'repaint_regions': snapshot.paintCount,
      'polygon_objects_created': snapshot.polygonObjectCreationCount,
      'polygon_objects_reused': snapshot.polygonObjectReuseCount,
    },
    'geometry': <String, num>{
      'samples': snapshot.visibleGeometrySampleCount,
      'average_visible_polygons': snapshot.visibleGeometrySampleCount == 0
          ? 0
          : snapshot.totalVisiblePolygonCount /
                snapshot.visibleGeometrySampleCount,
      'worst_visible_polygons': snapshot.maxVisiblePolygonCount,
      'average_visible_vertices': snapshot.visibleGeometrySampleCount == 0
          ? 0
          : snapshot.totalVisibleVertexCount /
                snapshot.visibleGeometrySampleCount,
      'worst_visible_vertices': snapshot.maxVisibleVertexCount,
      'submitted_polygons': snapshot.submittedPolygonCount,
      'submitted_vertices': snapshot.submittedVertexCount,
      'projected_polygons': snapshot.projectedPolygonCount,
      'projected_vertices': snapshot.projectedVertexCount,
      'projection_cache_hits': snapshot.projectedGeometryCacheHitCount,
    },
    'gc_events': _gcEventCount(timeline),
    'cache': <String, int>{
      'entries': cacheAfter.cachedTileCount,
      'maximum_entries': cacheAfter.maximumCachedTileCount,
      'hits': cacheAfter.cacheHitCount - cacheBefore.cacheHitCount,
      'misses': cacheAfter.decodedTileCount - cacheBefore.decodedTileCount,
      'coalesced':
          cacheAfter.coalescedRequestCount - cacheBefore.coalescedRequestCount,
      'visible_tiles': screenState.visibleTileCount as int,
      'prefetch_tiles': screenState.prefetchedTileCount as int,
      'rendered_tile_entries': screenState.renderedTileCacheSize as int,
    },
    'allocated_bytes': (allocations.members ?? const <ClassHeapStats>[])
        .fold<int>(0, (sum, item) => sum + (item.accumulatedSize ?? 0)),
    'allocated_instances': (allocations.members ?? const <ClassHeapStats>[])
        .fold<int>(0, (sum, item) => sum + (item.instancesAccumulated ?? 0)),
    'heap_delta_bytes':
        (memoryAfter.heapUsage ?? 0) - (memoryBefore.heapUsage ?? 0),
    'external_delta_bytes':
        (memoryAfter.externalUsage ?? 0) - (memoryBefore.externalUsage ?? 0),
  };
}

Map<String, Object?> _frameSummary(List<FrameTiming> timings, Duration wall) {
  final total = timings
      .map((timing) => timing.totalSpan.inMicroseconds)
      .toList();
  final ui = timings
      .map((timing) => timing.buildDuration.inMicroseconds)
      .toList();
  final raster = timings
      .map((timing) => timing.rasterDuration.inMicroseconds)
      .toList();
  final wallMicros = math.max(1, wall.inMicroseconds);

  return <String, Object?>{
    'frames': timings.length,
    'wall_us': wall.inMicroseconds,
    'throughput_fps': timings.length * 1000000 / wallMicros,
    'frame_rate_from_average': total.isEmpty ? 0 : 1000000 / _average(total),
    'minimum_fps': total.isEmpty ? 0 : 1000000 / total.reduce(math.max),
    'average_frame_us': _average(total),
    'worst_frame_us': total.isEmpty ? 0 : total.reduce(math.max),
    'p95_frame_us': _percentile(total, 0.95),
    'average_ui_us': _average(ui),
    'worst_ui_us': ui.isEmpty ? 0 : ui.reduce(math.max),
    'average_raster_us': _average(raster),
    'worst_raster_us': raster.isEmpty ? 0 : raster.reduce(math.max),
    'ui_utilization': ui.fold<int>(0, (sum, value) => sum + value) / wallMicros,
    'raster_utilization':
        raster.fold<int>(0, (sum, value) => sum + value) / wallMicros,
    'frames_over_16_7_ms': total.where((value) => value > 16667).length,
  };
}

Map<String, Object?> _timelineSummary(Timeline timeline) {
  var buildMicros = 0;
  var layoutMicros = 0;
  var paintMicros = 0;
  var rasterMicros = 0;
  var shaderMicros = 0;
  var shaderEvents = 0;

  for (final event in timeline.traceEvents ?? const <TimelineEvent>[]) {
    final json = event.json ?? const <String, dynamic>{};
    if (json['ph']?.toString() != 'X') continue;
    final name = json['name']?.toString().toLowerCase() ?? '';
    final duration = (json['dur'] as num?)?.round() ?? 0;
    if (name == 'build' || name.contains('buildframe')) {
      buildMicros += duration;
    } else if (name == 'layout' || name.contains('performlayout')) {
      layoutMicros += duration;
    } else if (name == 'paint' || name.contains('paintframe')) {
      paintMicros += duration;
    } else if (name.contains('raster')) {
      rasterMicros += duration;
    }
    if (name.contains('shader')) {
      shaderEvents++;
      shaderMicros += duration;
    }
  }

  return <String, Object?>{
    'build_us': buildMicros,
    'layout_us': layoutMicros,
    'paint_us': paintMicros,
    'raster_us': rasterMicros,
    'shader_events': shaderEvents,
    'shader_us': shaderMicros,
  };
}

Map<String, Object?> _cpuSummary(CpuSamples samples) {
  final period = samples.samplePeriod ?? 0;
  final categories = <String, int>{
    'pmtiles_read': 0,
    'mvt_decode_ui_isolate': 0,
    'polygon_generation': 0,
    'polygon_painting': 0,
    'hit_testing': 0,
    'widget_rebuilds': 0,
    'flutter_map_other': 0,
  };
  final ranked = <MapEntry<String, int>>[];

  for (final function in samples.functions ?? const <ProfileFunction>[]) {
    final ticks = function.exclusiveTicks ?? 0;
    if (ticks <= 0) {
      continue;
    }
    final micros = ticks * period;
    final url = (function.resolvedUrl ?? '').toLowerCase();
    final dynamic reference = function.function;
    final name = (reference?.name?.toString() ?? '').toLowerCase();
    final description = '$url::$name';
    final category = _cpuCategory(url, name);
    if (category != null) {
      categories[category] = categories[category]! + micros;
    }
    ranked.add(MapEntry(description, micros));
  }
  ranked.sort((left, right) => right.value.compareTo(left.value));

  return <String, Object?>{
    ...categories,
    'sample_period_us': period,
    'sample_count': samples.sampleCount ?? 0,
    'top_functions': [
      for (final entry in ranked.take(12))
        {'function': entry.key, 'cpu_us': entry.value},
    ],
  };
}

String? _cpuCategory(String url, String name) {
  if (url.contains('package:pmtiles') || url.contains('pmtiles-')) {
    return 'pmtiles_read';
  }
  if (url.contains('gis_repository') &&
      (name.contains('decode') || name.contains('projectpolygon'))) {
    return 'mvt_decode_ui_isolate';
  }
  if (url.contains('gis_map_screen') &&
      (name.contains('buildrendered') || name.contains('readring'))) {
    return 'polygon_generation';
  }
  if (name.contains('paint') &&
      (url.contains('flutter_map') || url.contains('gis_map_screen'))) {
    return 'polygon_painting';
  }
  if (name.contains('hittest') || name.contains('containspoint')) {
    return 'hit_testing';
  }
  if (name == 'build' &&
      (url.contains('flutter_map') || url.contains('gis_map_screen'))) {
    return 'widget_rebuilds';
  }
  if (url.contains('package:flutter_map') || url.contains('flutter_map-')) {
    return 'flutter_map_other';
  }
  return null;
}

int _timelineDuration(Timeline timeline, String targetName) {
  var total = 0;
  final starts = <String, List<int>>{};
  for (final event in timeline.traceEvents ?? const <TimelineEvent>[]) {
    final json = event.json ?? const <String, dynamic>{};
    if (json['name'] != targetName) {
      continue;
    }
    final phase = json['ph']?.toString();
    if (phase == 'X') {
      total += (json['dur'] as num?)?.round() ?? 0;
      continue;
    }
    final key = '${json['pid']}:${json['tid']}:${json['id'] ?? ''}';
    if (phase == 'B' || phase == 'b') {
      (starts[key] ??= <int>[]).add((json['ts'] as num).round());
    } else if ((phase == 'E' || phase == 'e') &&
        starts[key]?.isNotEmpty == true) {
      total += (json['ts'] as num).round() - starts[key]!.removeLast();
    }
  }
  return total;
}

int _gcEventCount(Timeline timeline) {
  return (timeline.traceEvents ?? const <TimelineEvent>[]).where((event) {
    final json = event.json ?? const <String, dynamic>{};
    final phase = json['ph']?.toString();
    final name = json['name']?.toString().toLowerCase() ?? '';
    return (phase == 'B' || phase == 'X') &&
        (name.contains('collectnewgeneration') ||
            name.contains('collectoldgeneration'));
  }).length;
}

Future<void> _continuousPan(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(FlutterMap));
  for (final delta in const [
    Offset(-5, 0),
    Offset(-5, 1),
    Offset(5, 0),
    Offset(5, -1),
  ]) {
    final gesture = await tester.startGesture(center);
    for (var frame = 0; frame < 38; frame++) {
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 190));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 90)),
    );
    await tester.pump();
  }
}

Future<void> _sustainedPan(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(FlutterMap));
  const deltas = <Offset>[
    Offset(-4, 0),
    Offset(0, -4),
    Offset(4, 0),
    Offset(0, 4),
  ];
  final gesture = await tester.startGesture(center);
  for (var cycle = 0; cycle < 3; cycle++) {
    for (final delta in deltas) {
      for (var frame = 0; frame < 75; frame++) {
        await gesture.moveBy(delta);
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 220));
}

Future<void> _panAndPinch(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(FlutterMap));
  final left = await tester.startGesture(
    center + const Offset(-70, 0),
    pointer: 11,
  );
  final right = await tester.startGesture(
    center + const Offset(70, 0),
    pointer: 12,
  );
  for (var frame = 0; frame < 60; frame++) {
    final zoomDirection = frame < 30 ? 1.0 : -1.0;
    await left.moveBy(Offset(-2 * zoomDirection + 1.2, 0.7));
    await right.moveBy(Offset(2 * zoomDirection + 1.2, 0.7));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await left.up();
  await right.up();
  await tester.pump(const Duration(milliseconds: 220));
}

Future<void> _toggleSoilLayer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Capas').first);
  await tester.pump();
  final soilTile = find.widgetWithText(SwitchListTile, 'Suelos');
  expect(soilTile, findsOneWidget);
  tester.widget<SwitchListTile>(soilTile).onChanged!(false);
  await tester.pump();
  tester.widget<SwitchListTile>(soilTile).onChanged!(true);
  await tester.pump();
}

Future<void> _desktopMouseWheelZoom(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(FlutterMap));
  for (var index = 0; index < 12; index++) {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: center,
        scrollDelta: Offset(0, index < 6 ? -120 : 120),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 220));
}

Future<void> _pinch(
  WidgetTester tester,
  Offset center, {
  required bool outward,
}) async {
  final left = await tester.startGesture(
    center + const Offset(-70, 0),
    pointer: 1,
  );
  final right = await tester.startGesture(
    center + const Offset(70, 0),
    pointer: 2,
  );
  final direction = outward ? 1.0 : -1.0;
  for (var frame = 0; frame < 44; frame++) {
    await left.moveBy(Offset(-2.2 * direction, 0));
    await right.moveBy(Offset(2.2 * direction, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await left.up();
  await right.up();
}

Future<void> _waitForTiles(
  WidgetTester tester,
  GisRenderMetrics metrics,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (metrics.polygonLayerBuildCount > 0 &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
  final labels = find
      .byType(Text)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .toList();
  fail(
    'Timed out waiting for GIS tiles. '
    'mapBuilds=${metrics.mapBuildCount}, '
    'tileBuilds=${metrics.tileCollectionBuildCount}, '
    'polygonBuilds=${metrics.polygonLayerBuildCount}, labels=$labels',
  );
}

double _average(List<int> values) {
  if (values.isEmpty) {
    return 0;
  }
  return values.fold<int>(0, (sum, value) => sum + value) / values.length;
}

int _percentile(List<int> values, double percentile) {
  if (values.isEmpty) {
    return 0;
  }
  final sorted = List<int>.of(values)..sort();
  return sorted[((sorted.length - 1) * percentile).round()];
}
