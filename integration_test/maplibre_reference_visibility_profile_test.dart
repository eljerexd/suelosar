import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reference labels survive zoom, pan, and return to zoom 7', (
    tester,
  ) async {
    final engine = MapLibreEngine();
    final repository = _ReferenceOnlyRepository();
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: repository, engine: engine),
      ),
    );
    await _waitForReferenceAndSprites(tester, engine);

    final initial = _snapshot(engine);
    debugPrint('MAPLIBRE_REFERENCE_STAGE initial ${jsonEncode(initial)}');
    expect(initial['referenceLoaded'], isTrue);
    expect((initial['labelOpacities'] as List).first, 1);
    expect(initial['boundaryVisibility'], everyElement(isTrue));
    final initialSymbols = await _waitForRenderedSymbols(tester, engine);
    expect(initialSymbols, greaterThan(0));
    await _holdForCapture(tester);

    final resumeCountBeforePdf = engine.debugRenderingResumeCount;
    final navigator = Navigator.of(tester.element(find.byType(GisMapScreen)));
    final coveredRoute = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('PDF'))),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await coveredRoute;
    await tester.pumpAndSettle();
    expect(engine.debugRenderingResumeCount, greaterThan(resumeCountBeforePdf));
    final symbolsAfterPdfReturn = await _waitForRenderedSymbols(tester, engine);
    expect(symbolsAfterPdfReturn, greaterThan(0));

    late Map<String, Object?> zoomed;
    late Map<String, Object?> returned;
    var returnedSymbols = 0;
    for (var cycle = 0; cycle < 3; cycle++) {
      engine.move(const LatLng(-36.5, -60), 14);
      await _waitForCamera(tester, engine, 14);
      engine.move(const LatLng(-35.8, -61), 14);
      await _waitForCamera(tester, engine, 14);
      zoomed = _snapshot(engine);
      debugPrint(
        'MAPLIBRE_REFERENCE_STAGE zoomed_${cycle + 1} '
        '${jsonEncode(zoomed)}',
      );
      expect(zoomed['labelOpacities'], everyElement(0));

      engine.move(const LatLng(-36.5, -60), 7);
      await _waitForCamera(tester, engine, 7);
      await tester.pump(const Duration(milliseconds: 250));
      returned = _snapshot(engine);
      debugPrint(
        'MAPLIBRE_REFERENCE_STAGE returned_${cycle + 1} '
        '${jsonEncode(returned)}',
      );
      expect((returned['labelOpacities'] as List).first, 1);
      expect(returned['boundaryVisibility'], everyElement(isTrue));
      returnedSymbols = await _waitForRenderedSymbols(tester, engine);
      expect(returnedSymbols, greaterThan(0));
    }
    await _holdForCapture(tester);

    await tester.pump(const Duration(seconds: 1));
    expect(_snapshot(engine), returned);
    binding.reportData = {
      'engine': 'MapLibre Native',
      'buildMode': 'profile',
      'initialZoom7': initial,
      'zoom14AfterPan': zoomed,
      'returnedZoom7': returned,
      'initialRenderedSymbols': initialSymbols,
      'symbolsAfterPdfReturn': symbolsAfterPdfReturn,
      'renderingResumesAfterPdf':
          engine.debugRenderingResumeCount - resumeCountBeforePdf,
      'returnedRenderedSymbols': returnedSymbols,
    };
    debugPrint(
      'MAPLIBRE_REFERENCE_VISIBILITY ${jsonEncode(binding.reportData)}',
    );
    expect(tester.takeException(), isNull);
  });
}

Map<String, Object?> _snapshot(MapLibreEngine engine) => {
  'zoom': engine.camera.zoom,
  'referenceLoaded': engine.debugReferenceBasemapLoaded,
  'labelSpritesReady': engine.debugReferenceLabelSpritesReady,
  'labelOpacities': engine.debugAdministrativeLabelOpacities,
  'boundaryVisibility': engine.debugAdministrativeBoundaryVisibility,
};

Future<void> _waitForReferenceAndSprites(
  WidgetTester tester,
  MapLibreEngine engine,
) async {
  final timeout = Stopwatch()..start();
  while (timeout.elapsed < const Duration(seconds: 90)) {
    final ready =
        engine.debugReferenceBasemapLoaded &&
        engine.debugReferenceLabelSpritesReady &&
        engine.debugAdministrativeLabelOpacities.every(
          (value) => value != null,
        );
    if (ready) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(
    'MapLibre reference label sprites did not become ready within 90 seconds.',
  );
}

Future<void> _waitForCamera(
  WidgetTester tester,
  MapLibreEngine engine,
  double expectedZoom,
) async {
  final timeout = Stopwatch()..start();
  while (timeout.elapsed < const Duration(seconds: 10)) {
    if ((engine.camera.zoom - expectedZoom).abs() < 0.05) {
      await tester.pump(const Duration(milliseconds: 250));
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail(
    'MapLibre camera did not reach zoom $expectedZoom; current zoom is '
    '${engine.camera.zoom}.',
  );
}

Future<int> _waitForRenderedSymbols(
  WidgetTester tester,
  MapLibreEngine engine,
) async {
  final timeout = Stopwatch()..start();
  while (timeout.elapsed < const Duration(seconds: 10)) {
    final count = await engine.debugRenderedReferenceSymbolCount();
    if (count > 0) return count;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('No rendered locality or administrative symbols on the map.');
}

Future<void> _holdForCapture(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  await tester.pump();
}

class _ReferenceOnlyRepository implements GisRepository {
  const _ReferenceOnlyRepository();

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 4,
    maxZoom: 18,
    centerLatitude: -36.5,
    centerLongitude: -60,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async => GisLayer(
    id: '${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
    name: 'empty reference test',
    features: const [],
  );

  @override
  Future<void> close() async {}
}
