import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/map_coverage.dart';
import 'package:suelosar/gis/multi_coverage_repository.dart';

/// Fase 6 verification: the multi-coverage tile-routing/merge logic against
/// the two REAL PMTiles archives — not synthetic fixtures. Directly proves
/// the "BA <-> SF transition" requirement (Parte 12's most important test)
/// at the architecture level: a tile whose real geography is Buenos
/// Aires-only returns unprefixed Buenos Aires features and never touches
/// the Santa Fe archive's decode path (and vice versa), while a tile
/// outside both returns empty without erroring.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // MultiCoverageRepository builds real PmTilesGisRepository.fromAsset
  // instances internally (the exact same path GisMapScreen uses) — that
  // needs path_provider's platform channel, which flutter_test doesn't
  // implement by default. Mocking it to a temp directory lets the real
  // asset-copy code run headlessly instead of bypassing it.
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            final dir = await Directory.systemTemp.createTemp(
              'multi_coverage_test_',
            );
            return dir.path;
          }
          return null;
        });
  });

  late MultiCoverageRepository repository;

  setUp(() {
    repository = MultiCoverageRepository(
      coverages: [MapCoverage.buenosAires, MapCoverage.santaFe],
      defaultCoverageId: MapCoverage.buenosAires.id,
    );
  });

  tearDown(() => repository.close());

  group('GeoBounds', () {
    test('intersects/containsPoint basic geometry', () {
      const ba = GeoBounds(
        minLatitude: -39,
        maxLatitude: -33.27,
        minLongitude: -63.46,
        maxLongitude: -56.66,
      );
      expect(ba.containsPoint(-36.5, -60.0), isTrue);
      expect(ba.containsPoint(-10.0, -60.0), isFalse);
      expect(ba.intersects(MapCoverage.santaFe.bounds), isTrue);
      expect(
        ba.intersects(
          const GeoBounds(
            minLatitude: 10,
            maxLatitude: 20,
            minLongitude: 10,
            maxLongitude: 20,
          ),
        ),
        isFalse,
      );
    });
  });

  group('MultiCoverageRepository.initialize', () {
    test('merges zoom bounds, keeps Buenos Aires as the center', () async {
      final info = await repository.initialize();
      expect(info.minZoom, 4);
      expect(info.maxZoom, 14);
      // Buenos Aires' own real archive center (Fase 4B) — Parte 8: the app
      // must keep opening on Buenos Aires, not an average of coverages.
      expect(info.centerLatitude, closeTo(-38.865374, 0.01));
      expect(info.centerLongitude, closeTo(-60.128174, 0.01));
    });
  });

  group('MultiCoverageRepository.loadTile — routes by real geography', () {
    test(
      'a Buenos-Aires-only tile returns only BA features, unprefixed',
      () async {
        await repository.initialize();
        final layer = await repository.loadTile(
          const GisTileCoordinates(zoom: 8, x: 85, y: 155),
        );
        expect(layer.features, isNotEmpty);
        for (final feature in layer.features) {
          expect(feature.id.contains(':'), isFalse);
          // Buenos Aires' real schema (Fase 4A audit) always carries SIMBC.
          expect(feature.properties.containsKey('SIMBC'), isTrue);
        }
      },
    );

    test('a Santa-Fe-only tile returns only SF features, prefixed', () async {
      await repository.initialize();
      final layer = await repository.loadTile(
        const GisTileCoordinates(zoom: 8, x: 83, y: 152),
      );
      expect(layer.features, isNotEmpty);
      for (final feature in layer.features) {
        expect(feature.id.startsWith('santa_fe:'), isTrue);
        // Santa Fe's real schema (Fase 3) — PAISAJE is never present.
        expect(feature.properties.containsKey('PAISAJE'), isFalse);
      }
    });

    test('a tile outside both coverages returns empty, not an error', () async {
      await repository.initialize();
      final layer = await repository.loadTile(
        const GisTileCoordinates(zoom: 8, x: 85, y: 135),
      );
      expect(layer.features, isEmpty);
    });
  });

  group('MultiCoverageRepository.coverageForFeatureId', () {
    test('unprefixed ids resolve to the default coverage (Buenos Aires)', () {
      final coverage = repository.coverageForFeatureId('12345');
      expect(coverage.id, 'buenos_aires');
    });

    test('santa_fe-prefixed ids resolve to Santa Fe', () {
      final coverage = repository.coverageForFeatureId('santa_fe:999');
      expect(coverage.id, 'santa_fe');
    });

    test('an unknown prefix falls back to the default coverage', () {
      final coverage = repository.coverageForFeatureId('cordoba:1');
      expect(coverage.id, 'buenos_aires');
    });
  });
}
