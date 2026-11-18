import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';
import 'package:suelosar/gis/engine/maplibre_reference_basemap.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/province_config.dart';

const _areaCount = 32;
const _minimumAreaSeparationKm = 22.0;
const _zoomIn = 12.0;
const _zoomOut = 7.0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('locality symbols survive 32 distinct zoom-and-pan areas', (
    tester,
  ) async {
    var engine = MapLibreEngine();
    final provinceConfig = _cordobaTestConfig();

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(engine: engine, provinceConfig: provinceConfig),
      ),
    );
    await _waitForReferenceAndSprites(tester, engine);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();

    final centers = _distinctCenters(engine.debugLocalityFeatures);
    expect(centers, hasLength(_areaCount));

    final movementLog = <Map<String, Object?>>[];
    final firstVisitById = <String, Map<String, Object?>>{};
    final cumulativeRegressions = <Map<String, Object?>>[];
    final primaryLabelFailures = <Map<String, Object?>>[];
    final dotWithoutName = <Map<String, Object?>>[];
    final firstVisitMissingNames = <Map<String, Object?>>[];
    var firstMissingNameScreenshotTaken = false;
    Map<String, Object?>? firstMissingTargetCollisionProbe;
    Map<String, Object?>? labelLayerRefreshProbe;
    Map<String, Object?>? spriteReregistrationProbe;
    var cameraMovementCount = 0;
    var geographicAreaTransitions = 0;

    final initialCenter = centers.first;
    await _moveAndWaitForIdle(tester, engine, initialCenter.point, _zoomIn);
    cameraMovementCount++;
    geographicAreaTransitions++;
    final initial = await _checkpoint(
      tester,
      engine,
      initialCenter,
      areaIndex: 0,
      zoomStage: 'initial_zoom12',
      cameraMovementCount: cameraMovementCount,
      geographicAreaTransitions: geographicAreaTransitions,
    );
    firstVisitById[initialCenter.id] = initial;
    await _screenshot(binding, tester, 'locality-area-00-initial-z12');
    debugPrint('LOCALITY_AREA ${jsonEncode(initial)}');

    for (var areaIndex = 0; areaIndex < centers.length; areaIndex++) {
      final center = centers[areaIndex];
      if (areaIndex == 0) {
        await _moveAndWaitForIdle(
          tester,
          engine,
          initialCenter.point,
          _zoomOut,
        );
      } else {
        await _moveAndWaitForIdle(
          tester,
          engine,
          centers[areaIndex - 1].point,
          _zoomOut,
        );
      }
      cameraMovementCount++;
      final atZoom7 = await _checkpoint(
        tester,
        engine,
        centers[areaIndex == 0 ? 0 : areaIndex - 1],
        areaIndex: areaIndex,
        zoomStage: 'zoom7_before_pan',
        cameraMovementCount: cameraMovementCount,
        geographicAreaTransitions: geographicAreaTransitions,
      );
      movementLog.add(atZoom7);
      if (areaIndex == 0) {
        await _screenshot(binding, tester, 'locality-area-00-after-zoomout-z7');
      }

      if (areaIndex > 0) {
        final distance = _distanceKm(
          centers[areaIndex - 1].point,
          center.point,
        );
        expect(
          distance,
          greaterThanOrEqualTo(_minimumAreaSeparationKm),
          reason: 'Area $areaIndex must be geographically distinct.',
        );
        await _moveAndWaitForIdle(tester, engine, center.point, _zoomOut);
        cameraMovementCount++;
        geographicAreaTransitions++;
      }

      await _moveAndWaitForIdle(tester, engine, center.point, _zoomIn);
      cameraMovementCount++;
      final zoom12 = await _checkpoint(
        tester,
        engine,
        center,
        areaIndex: areaIndex,
        zoomStage: 'zoom12_after_pan',
        cameraMovementCount: cameraMovementCount,
        geographicAreaTransitions: geographicAreaTransitions,
      );
      movementLog.add(zoom12);
      debugPrint('LOCALITY_AREA ${jsonEncode(zoom12)}');
      debugPrint(
        'LOCALITY_TARGET ${jsonEncode({'areaIndex': areaIndex, 'name': center.name, 'id': center.id, 'sourcePresent': zoom12['sourceFeaturePresent'], 'sourceProperties': zoom12['sourceProperties'], 'labelImageRegistered': zoom12['expectedLabelImageRegistered'], 'targetDotRendered': zoom12['targetDotRendered'], 'targetLabelRendered': zoom12['targetLabelRendered'], 'dotOnly': zoom12['dotWithoutNameFeatures'], 'renderedNames': zoom12['renderedLocalityNames'], 'labelLayerPlacement': zoom12['labelLayerPlacement']})}',
      );
      if (areaIndex == 1 ||
          areaIndex == 8 ||
          areaIndex == 16 ||
          areaIndex == 31) {
        await _screenshot(
          binding,
          tester,
          'locality-area-${areaIndex.toString().padLeft(2, '0')}-z12',
        );
      }

      final dotRendered = zoom12['targetDotRendered'] == true;
      final nameRendered = zoom12['targetLabelRendered'] == true;
      if (center.isPrimary && !nameRendered) {
        primaryLabelFailures.add({
          'areaIndex': areaIndex,
          'localityId': center.id,
          'localityName': center.name,
          'checkpoint': zoom12,
        });
      }
      final dotOnlyFeatures =
          zoom12['dotWithoutNameFeatures'] as List<dynamic>? ?? const [];
      if (dotOnlyFeatures.isNotEmpty) {
        dotWithoutName.add({
          'areaIndex': areaIndex,
          'targetName': center.name,
          'applicationZoom': zoom12['applicationZoom'],
          'nativeZoom': zoom12['nativeZoom'],
          'dotWithoutNameFeatures': dotOnlyFeatures,
        });
      }
      if (dotRendered && !nameRendered) {
        final missing = {
          ...zoom12,
          'classification': firstVisitById.containsKey(center.id)
              ? 'revisit_dot_without_name'
              : 'first_visit_dot_without_name',
        };
        if (areaIndex == 1 ||
            areaIndex == 8 ||
            areaIndex == 16 ||
            areaIndex == 31) {
          await _screenshot(
            binding,
            tester,
            'locality-dot-without-name-area-'
            '${areaIndex.toString().padLeft(2, '0')}',
          );
        }
        debugPrint('LOCALITY_DOT_WITHOUT_NAME ${jsonEncode(missing)}');
      }
      if (!nameRendered) {
        firstVisitMissingNames.add({
          'areaIndex': areaIndex,
          'targetName': center.name,
          'targetId': center.id,
          'dotRendered': dotRendered,
          'nameRendered': nameRendered,
          'renderedLocalityCount': zoom12['renderedLocalityCount'],
          'dotWithoutNameFeatures': dotOnlyFeatures,
          'runtime': zoom12,
        });
      }
      if (!nameRendered && !firstMissingNameScreenshotTaken) {
        firstMissingNameScreenshotTaken = true;
        await _screenshot(
          binding,
          tester,
          'locality-first-target-name-missing-area-'
          '${areaIndex.toString().padLeft(2, '0')}',
        );
      }
      if (dotRendered &&
          !nameRendered &&
          firstMissingTargetCollisionProbe == null) {
        engine.debugSetSecondaryLocalityLabelPlacement(
          allowOverlap: true,
          ignorePlacement: true,
          forceOpaque: true,
          targetCityId: center.id,
          forcedImageId:
              (zoom12['sourceProperties']
                      as Map<String, Object?>)['labelImage']!
                  as String,
        );
        await tester.pump(const Duration(milliseconds: 500));
        final overlapProbe = await _checkpoint(
          tester,
          engine,
          center,
          areaIndex: areaIndex,
          zoomStage: 'diagnostic_only_target_overlap_enabled',
          cameraMovementCount: cameraMovementCount,
          geographicAreaTransitions: geographicAreaTransitions,
        );
        await _screenshot(
          binding,
          tester,
          'locality-target-missing-overlap-enabled',
        );
        firstMissingTargetCollisionProbe = {
          'areaIndex': areaIndex,
          'targetName': center.name,
          'targetDotRendered': zoom12['targetDotRendered'],
          'targetNameRenderedBefore': zoom12['targetLabelRendered'],
          'targetNameRenderedWithOverlap': overlapProbe['targetLabelRendered'],
          'targetNameRenderedForcedPlacementAndOpacity':
              overlapProbe['targetLabelRendered'],
          'targetNameRenderedWithLiteralRegisteredImage':
              overlapProbe['targetLabelRendered'],
          'renderedNamesBefore': zoom12['renderedLocalityNames'],
          'renderedNamesWithOverlap': overlapProbe['renderedLocalityNames'],
          'dotWithoutNameBefore': dotOnlyFeatures,
          'dotWithoutNameAfter': overlapProbe['dotWithoutNameFeatures'],
          'temporaryStyleOverride': {
            'iconAllowOverlap': true,
            'iconIgnorePlacement': true,
            'iconOpacity': 1,
          },
        };
        engine.debugSetSecondaryLocalityLabelPlacement(
          allowOverlap: false,
          ignorePlacement: false,
          forceOpaque: false,
        );
        await tester.pump(const Duration(milliseconds: 500));
      }

      final firstVisit = firstVisitById[center.id];
      if (firstVisit != null &&
          firstVisit['targetLabelRendered'] == true &&
          dotRendered &&
          !nameRendered) {
        cumulativeRegressions.add({
          'areaIndex': areaIndex,
          'localityId': center.id,
          'localityName': center.name,
          'firstVisit': firstVisit,
          'revisit': zoom12,
        });
      } else {
        firstVisitById.putIfAbsent(center.id, () => zoom12);
      }

      expect(
        zoom12['sourcePresent'],
        isTrue,
        reason: 'Locality source missing at area $areaIndex.',
      );
      expect(
        zoom12['sourceLocalityCount'],
        greaterThan(0),
        reason: 'No locality features remain in source at area $areaIndex.',
      );
      expect(
        zoom12['primaryLayerVisible'],
        isTrue,
        reason: 'Primary name-symbol layer hidden at area $areaIndex.',
      );
      expect(
        zoom12['targetInsideViewport'],
        isTrue,
        reason: 'Target locality ${center.name} is outside the viewport.',
      );
      expect(
        zoom12['nativeZoom'],
        closeTo(_zoomIn - 1, 0.8),
        reason: 'MapLibre native zoom diverged from application zoom.',
      );
      expect(
        zoom12['sourceUpdateCount'],
        initial['sourceUpdateCount'],
        reason: 'Static locality GeoJSON was unexpectedly resubmitted.',
      );
      expect(
        zoom12['sourceLocalityCount'],
        initial['sourceLocalityCount'],
        reason: 'Locality source feature count changed during navigation.',
      );

      if (areaIndex == 0 || areaIndex == 15 || areaIndex == 31) {
        await tester.pump(const Duration(milliseconds: 350));
        final delayed = await _checkpoint(
          tester,
          engine,
          center,
          areaIndex: areaIndex,
          zoomStage: 'zoom12_settled_delay',
          cameraMovementCount: cameraMovementCount,
          geographicAreaTransitions: geographicAreaTransitions,
        );
        expect(delayed['queryAvailable'], isTrue);
        expect(delayed['sourcePresent'], isTrue);
        expect(delayed['secondaryLayerVisible'], isTrue);
      }
    }

    expect(geographicAreaTransitions, greaterThanOrEqualTo(31));
    expect(cameraMovementCount, greaterThanOrEqualTo(90));

    // Revisit an area known to have a visible target label before the long
    // navigation run. A missing sprite after 31 other centers is a true
    // cumulative regression, not a normal collision on first visit.
    final revisitCenters = centers
        .where(
          (city) => firstVisitById[city.id]?['targetLabelRendered'] == true,
        )
        .take(4)
        .toList(growable: false);
    for (var index = 0; index < revisitCenters.length; index++) {
      final city = revisitCenters[index];
      await _moveAndWaitForIdle(tester, engine, city.point, _zoomIn);
      cameraMovementCount++;
      final revisit = await _checkpoint(
        tester,
        engine,
        city,
        areaIndex: centers.indexOf(city),
        zoomStage: 'revisit_after_32_areas',
        cameraMovementCount: cameraMovementCount,
        geographicAreaTransitions: geographicAreaTransitions,
      );
      movementLog.add(revisit);
      if (revisit['targetDotRendered'] == true &&
          revisit['targetLabelRendered'] != true) {
        cumulativeRegressions.add({
          'areaIndex': centers.indexOf(city),
          'localityId': city.id,
          'localityName': city.name,
          'firstVisit': firstVisitById[city.id],
          'revisit': revisit,
        });
        await _screenshot(
          binding,
          tester,
          'locality-cumulative-loss-${index.toString().padLeft(2, '0')}',
        );
      }
    }

    final sourceUpdatesBeforeReopen = engine.debugCitySourceUpdates;
    final sourceUpdateCountBeforeReopen =
        engine.debugLocalityRuntimeSnapshot['sourceUpdateCount'];
    final firstMissingLocalityId = firstVisitMissingNames.isEmpty
        ? null
        : firstVisitMissingNames.first['targetId'];
    final failedLocality = cumulativeRegressions.isNotEmpty
        ? centers.firstWhere(
            (city) => city.id == cumulativeRegressions.first['localityId'],
          )
        : firstMissingLocalityId == null
        ? null
        : centers.firstWhere((city) => city.id == firstMissingLocalityId);
    Map<String, Object?>? failureSecondZoom;
    if (failedLocality != null) {
      await _moveAndWaitForIdle(tester, engine, failedLocality.point, _zoomOut);
      await _moveAndWaitForIdle(tester, engine, failedLocality.point, _zoomIn);
      failureSecondZoom = await _checkpoint(
        tester,
        engine,
        failedLocality,
        areaIndex: centers.indexOf(failedLocality),
        zoomStage: 'first_failure_same_area_zoomed_in_again',
        cameraMovementCount: cameraMovementCount + 3,
        geographicAreaTransitions: geographicAreaTransitions,
      );
      await _screenshot(binding, tester, 'locality-first-failure-rezoom-z12');
      engine.debugRefreshLocalityLabelLayers();
      await tester.pump(const Duration(milliseconds: 500));
      labelLayerRefreshProbe = await _checkpoint(
        tester,
        engine,
        failedLocality,
        areaIndex: centers.indexOf(failedLocality),
        zoomStage: 'diagnostic_only_label_layer_refresh',
        cameraMovementCount: cameraMovementCount + 3,
        geographicAreaTransitions: geographicAreaTransitions,
      );
      await _screenshot(binding, tester, 'locality-after-label-layer-refresh');
      await engine.debugRefreshLocalityLabelImage(failedLocality.id);
      await tester.pump(const Duration(milliseconds: 500));
      spriteReregistrationProbe = await _checkpoint(
        tester,
        engine,
        failedLocality,
        areaIndex: centers.indexOf(failedLocality),
        zoomStage: 'diagnostic_only_target_sprite_reregistered',
        cameraMovementCount: cameraMovementCount + 3,
        geographicAreaTransitions: geographicAreaTransitions,
      );
      await _screenshot(
        binding,
        tester,
        'locality-after-target-sprite-reregister',
      );
    }

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    engine.dispose();
    engine = MapLibreEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(engine: engine, provinceConfig: provinceConfig),
      ),
    );
    await _waitForReferenceAndSprites(tester, engine);
    final reopenCenter = cumulativeRegressions.isNotEmpty
        ? centers.firstWhere(
            (city) => city.id == cumulativeRegressions.first['localityId'],
          )
        : revisitCenters.isNotEmpty
        ? revisitCenters.first
        : centers.first;
    await _moveAndWaitForIdle(tester, engine, reopenCenter.point, _zoomIn);
    final navigationRecovery = await _checkpoint(
      tester,
      engine,
      reopenCenter,
      areaIndex: centers.indexOf(reopenCenter),
      zoomStage: 'after_leave_and_reopen',
      cameraMovementCount: cameraMovementCount + 1,
      geographicAreaTransitions: geographicAreaTransitions,
    );
    await _screenshot(binding, tester, 'locality-after-gis-reopen-z12');
    final reopenBaseline = firstVisitById[reopenCenter.id];
    if (reopenBaseline?['targetLabelRendered'] == true) {
      expect(navigationRecovery['targetLabelRendered'], isTrue);
    }
    if (reopenBaseline?['targetLabelRendered'] == true) {
      expect(navigationRecovery['targetLabelRendered'], isTrue);
    }

    binding.reportData = {
      if (binding.reportData != null) ...binding.reportData!,
      'localityMultiAreaReport': {
        'scenario': 'zoom12_zoom7_pan_distinct_center_zoom12',
        'areaCount': centers.length,
        'minimumAreaSeparationKm': _minimumAreaSeparationKm,
        'cameraMovementCount': cameraMovementCount,
        'geographicAreaTransitions': geographicAreaTransitions,
        'initialArea': initial,
        'movementCheckpoints': movementLog,
        'dotRenderedWithoutName': dotWithoutName,
        'firstVisitMissingNames': firstVisitMissingNames,
        'primaryLabelFailures': primaryLabelFailures,
        'cumulativeRegressions': cumulativeRegressions,
        'spriteReconciliations': engine.debugLocalitySpriteReconciliations,
        'successfulSpriteRefreshes': engine.debugLocalitySpriteRefreshes,
        'firstMissingTargetCollisionProbe': firstMissingTargetCollisionProbe,
        'firstFailureSecondZoom': failureSecondZoom,
        'labelLayerRefreshProbe': labelLayerRefreshProbe,
        'spriteReregistrationProbe': spriteReregistrationProbe,
        'sourceUpdatesBeforeReopen': sourceUpdatesBeforeReopen,
        'sourceUpdateCountBeforeReopen': sourceUpdateCountBeforeReopen,
        'sourceUpdatesAfterReopen': engine.debugCitySourceUpdates,
        'navigationRecovery': navigationRecovery,
        'symbolPlacementConfiguration':
            navigationRecovery['labelLayerPlacement'],
      },
    };
    debugPrint('LOCALITY_MULTIAREA_REPORT ${jsonEncode(binding.reportData)}');
    expect(
      cumulativeRegressions,
      isEmpty,
      reason:
          'A previously rendered locality label disappeared after '
          'navigating across distinct areas.',
    );
    expect(
      primaryLabelFailures,
      isEmpty,
      reason: 'Primary locality labels must render at application zoom 12.',
    );
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Future<Map<String, Object?>> _checkpoint(
  WidgetTester tester,
  MapLibreEngine engine,
  MapLibreReferenceCity target, {
  required int areaIndex,
  required String zoomStage,
  required int cameraMovementCount,
  required int geographicAreaTransitions,
}) async {
  final snapshot = engine.debugLocalityRuntimeSnapshot;
  final targetRender = await engine.debugRenderedLocalityAt(target);
  final renderedFeatures = await engine.debugRenderedLocalityFeatureRecords();
  final appZoom = engine.camera.zoom;
  return {
    ...snapshot,
    ...targetRender,
    'areaIndex': areaIndex,
    'zoomStage': zoomStage,
    'targetCenter': {
      'latitude': target.point.latitude,
      'longitude': target.point.longitude,
      'name': target.name,
      'id': target.id,
    },
    'cameraMovementCount': cameraMovementCount,
    'geographicAreaTransitions': geographicAreaTransitions,
    'applicationZoom': appZoom,
    'nativeZoom': snapshot['nativeZoom'],
    'expectedLocalityCountInViewport': snapshot['localityCandidatesInViewport'],
    'renderedLocalityCount': renderedFeatures.length,
    'renderedLocalityFeatures': renderedFeatures,
    'renderedLocalityNames': renderedFeatures
        .map((feature) => feature['name'])
        .whereType<String>()
        .toList(growable: false),
    'spriteReconciliationCount': engine.debugLocalitySpriteReconciliationCount,
    'spriteReconciliations': engine.debugLocalitySpriteReconciliations,
    'successfulSpriteRefreshes': engine.debugLocalitySpriteRefreshes,
  };
}

Future<void> _screenshot(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await tester.pump(const Duration(milliseconds: 100));
  await binding.takeScreenshot(name);
}

List<MapLibreReferenceCity> _distinctCenters(
  List<Map<String, Object?>> rawCities,
) {
  final cities = rawCities
      .map(
        (record) => MapLibreReferenceCity(
          id: record['id']! as String,
          name: record['name']! as String,
          point: LatLng(
            record['latitude']! as double,
            record['longitude']! as double,
          ),
          isPrimary: record['isPrimary']! as bool,
          provinceId: record['provinceId']! as String,
          minZoom: record['minZoom']! as double,
        ),
      )
      .toList(growable: false);
  if (cities.isEmpty) return const [];

  final selected = <MapLibreReferenceCity>[];
  final first = cities.firstWhere(
    (city) => city.name == 'Villa Dolores',
    orElse: () => cities.first,
  );
  selected.add(first);
  for (final primaryName in const ['Córdoba', 'Río Cuarto']) {
    final primary = cities.firstWhere(
      (city) => city.isPrimary && city.name == primaryName,
      orElse: () => throw StateError('Missing expected primary $primaryName.'),
    );
    if (selected.every(
      (prior) =>
          _distanceKm(prior.point, primary.point) >= _minimumAreaSeparationKm,
    )) {
      selected.add(primary);
    }
  }
  final remaining = cities
      .where(
        (city) =>
            !city.isPrimary && !selected.any((prior) => prior.id == city.id),
      )
      .toList();
  while (selected.length < _areaCount && remaining.isNotEmpty) {
    var bestIndex = -1;
    var bestDistance = -1.0;
    for (var index = 0; index < remaining.length; index++) {
      final nearest = selected
          .map((prior) => _distanceKm(prior.point, remaining[index].point))
          .reduce(math.min);
      if (nearest > bestDistance) {
        bestIndex = index;
        bestDistance = nearest;
      }
    }
    if (bestIndex < 0 || bestDistance < _minimumAreaSeparationKm) break;
    selected.add(remaining.removeAt(bestIndex));
  }
  return selected;
}

double _distanceKm(LatLng first, LatLng second) {
  const kmPerDegree = 111.32;
  final meanLatitude = (first.latitude + second.latitude) * math.pi / 360;
  final northSouth = (first.latitude - second.latitude) * kmPerDegree;
  final eastWest =
      (first.longitude - second.longitude) *
      math.cos(meanLatitude) *
      kmPerDegree;
  return math.sqrt(northSouth * northSouth + eastWest * eastWest);
}

Future<void> _waitForReferenceAndSprites(
  WidgetTester tester,
  MapLibreEngine engine,
) async {
  final timeout = Stopwatch()..start();
  while (timeout.elapsed < const Duration(seconds: 120)) {
    final state = engine.debugLocalityRuntimeSnapshot;
    if (engine.debugReferenceBasemapLoaded &&
        engine.debugReferenceLabelSpritesReady &&
        state['sourcePresent'] == true &&
        state['primaryLayerVisible'] == true) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Locality data/source/layers did not become ready in 120 seconds.');
}

Future<void> _moveAndWaitForIdle(
  WidgetTester tester,
  MapLibreEngine engine,
  LatLng center,
  double zoom,
) async {
  final mapIdleCountBefore = engine.debugNativeMapIdleCount;
  engine.move(center, zoom);
  final timeout = Stopwatch()..start();
  var stillFrames = 0;
  var previous = engine.camera;
  while (timeout.elapsed < const Duration(seconds: 10)) {
    await tester.pump(const Duration(milliseconds: 60));
    final current = engine.camera;
    final settledAtTarget =
        (current.zoom - zoom).abs() < 0.25 &&
        (current.center.latitude - center.latitude).abs() < 0.001 &&
        (current.center.longitude - center.longitude).abs() < 0.001;
    final stable =
        (current.zoom - previous.zoom).abs() < 0.01 &&
        (current.center.latitude - previous.center.latitude).abs() < 0.00001 &&
        (current.center.longitude - previous.center.longitude).abs() < 0.00001;
    if (settledAtTarget && stable) {
      stillFrames++;
      if (stillFrames >= 3) {
        await _waitForSpriteReconciliation(tester, engine, mapIdleCountBefore);
        return;
      }
    } else {
      stillFrames = 0;
    }
    previous = current;
  }
  fail(
    'Camera did not settle at center $center, zoom $zoom; '
    'actual=${engine.camera}.',
  );
}

Future<void> _waitForSpriteReconciliation(
  WidgetTester tester,
  MapLibreEngine engine,
  int previousMapIdleCount,
) async {
  for (var frame = 0; frame < 200; frame++) {
    if (engine.debugNativeMapIdleCount > previousMapIdleCount &&
        engine.debugPendingLocalitySpriteReconciliations == 0) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 40));
  }
  fail(
    'MapLibre did not finish its idle/render reconciliation after camera '
    'settled. previousIdle=$previousMapIdleCount, '
    'currentIdle=${engine.debugNativeMapIdleCount}, '
    'pending=${engine.debugPendingLocalitySpriteReconciliations}, '
    'completed=${engine.debugLocalitySpriteReconciliationCount}.',
  );
}

ProvinceConfig _cordobaTestConfig() {
  final base = ProvinceConfig.cordoba;
  const center = LatLng(-31.94, -65.19);
  final archive = base.defaultArchiveInfo;
  return ProvinceConfig(
    id: base.id,
    pmtilesAsset: base.pmtilesAsset,
    pmtilesVersionAsset: base.pmtilesVersionAsset,
    pmtilesLayerName: base.pmtilesLayerName,
    initialCenter: center,
    defaultArchiveInfo: GisArchiveInfo(
      minZoom: archive.minZoom,
      maxZoom: archive.maxZoom,
      centerLatitude: center.latitude,
      centerLongitude: center.longitude,
    ),
    seriesResolver: base.seriesResolver,
    seriesNameResolver: base.seriesNameResolver,
    downloadMetadata: base.downloadMetadata,
    referenceMapAsset: base.referenceMapAsset,
    preloadSeriesNames: base.preloadSeriesNames,
    downloadBannerAnchor: base.downloadBannerAnchor,
    showPolygonUnitSymbols: base.showPolygonUnitSymbols,
    pmtilesDownloadSizeBytes: base.pmtilesDownloadSizeBytes,
  );
}
