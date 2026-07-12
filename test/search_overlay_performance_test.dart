import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/models/personal_marker.dart';

void main() {
  testWidgets('full-screen search pauses and restores visual map layers', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    final marker = PersonalMarker(
      id: 'search-overlay-marker',
      latitude: -36.5,
      longitude: -60,
      name: 'Marcador',
      description: '',
      createdAt: DateTime.utc(2026, 7, 12),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      PersonalMarker.storageKey: <String>[jsonEncode(marker.toJson())],
    });

    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyRepository())),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MarkerLayer), findsOneWidget);

    await tester.tap(find.byTooltip('Buscar'));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(GisMapScreen));
    expect(state.mapVisualsPaused, isTrue);
    expect(find.byType(MarkerLayer), findsNothing);

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    expect(state.mapVisualsPaused, isFalse);
    expect(find.byType(MarkerLayer), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('floating desktop search keeps visual map layers active', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final metrics = GisRenderMetrics();
    addTearDown(metrics.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: const _EmptyRepository(),
          renderMetrics: metrics,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    metrics.reset();
    await tester.tap(find.byTooltip('Buscar'));
    await tester.pumpAndSettle();

    final dynamic state = tester.state(find.byType(GisMapScreen));
    expect(state.mapVisualsPaused, isFalse);
    expect(metrics.mapBuildCount, 0);
    debugDefaultTargetPlatformOverride = null;
  });
}

class _EmptyRepository implements GisRepository {
  const _EmptyRepository();

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 7,
    maxZoom: 14,
    centerLatitude: -36.5,
    centerLongitude: -60,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async => GisLayer(
    id: '${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
    name: 'empty',
    features: const [],
  );

  @override
  Future<void> close() async {}
}
