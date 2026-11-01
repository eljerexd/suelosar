import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';

void main() {
  testWidgets('province download controls paint above provincial highlights', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyRepository())),
    );
    await tester.pump(const Duration(seconds: 1));

    const coverageIds = {'buenos_aires', 'santa_fe', 'cordoba'};
    final overlayStack = tester
        .widgetList<Stack>(find.byType(Stack))
        .singleWhere((stack) {
          final keys = stack.children.map((child) => child.key).toSet();
          return keys.contains(
            const ValueKey('province-pmtiles-highlight-cordoba'),
          );
        });
    final keys = overlayStack.children.map((child) => child.key).toList();
    final highlightIndexes = [
      for (final id in coverageIds)
        keys.indexOf(ValueKey('province-pmtiles-highlight-$id')),
    ];
    final overlayIndex = keys.indexOf(
      const ValueKey('province-download-map-overlay'),
    );

    expect(highlightIndexes, everyElement(greaterThanOrEqualTo(0)));
    expect(
      highlightIndexes.reduce((a, b) => a > b ? a : b),
      lessThan(overlayIndex),
    );
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
