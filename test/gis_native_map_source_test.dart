import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/gis/map_coverage.dart';
import 'package:suelosar/gis/multi_coverage_repository.dart';
import 'package:suelosar/gis/native_map_source.dart';

void main() {
  test(
    'native sources include only available coverages with stable identity',
    () async {
      final repository = MultiCoverageRepository(
        coverages: [MapCoverage.buenosAires, MapCoverage.santaFe],
        defaultCoverageId: MapCoverage.buenosAires.id,
        isCoverageAvailable: (coverage) async => coverage.id == 'buenos_aires',
        repositoryBuilder: (coverage) =>
            _NativeRepository(coverage.id, '/offline/${coverage.id}.pmtiles'),
      );
      addTearDown(repository.close);

      final initialSources = await repository.getNativeMapSources();
      expect(initialSources, hasLength(1));
      expect(initialSources.single.id, 'soil-buenos_aires');
      expect(initialSources.single.coverageId, 'buenos_aires');
      expect(initialSources.single.layerName, 'soil_polygons');
      expect(
        initialSources.single.archivePath,
        '/offline/buenos_aires.pmtiles',
      );
      expect(initialSources.single.defaultCoverage, isTrue);

      await repository.markCoverageAvailable('santa_fe');
      final updatedSources = await repository.getNativeMapSources();
      expect(updatedSources, hasLength(2));
      final santaFe = updatedSources.singleWhere(
        (source) => source.coverageId == 'santa_fe',
      );
      expect(santaFe.id, 'soil-santa_fe');
      expect(santaFe.archivePath, '/offline/santa_fe.pmtiles');
      expect(santaFe.defaultCoverage, isFalse);
    },
  );
}

class _NativeRepository implements GisRepository, GisNativeMapSourceProvider {
  _NativeRepository(this.coverageId, this.archivePath);

  final String coverageId;
  final String archivePath;

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 4,
    maxZoom: 14,
    centerLatitude: 0,
    centerLongitude: 0,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async => GisLayer(
    id: 'test-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
    name: 'soil_polygons',
    features: const <GisFeature>[],
  );

  @override
  Future<List<GisNativeMapSource>> getNativeMapSources() async => [
    GisNativeMapSource(
      id: 'source-$coverageId',
      coverageId: coverageId,
      layerName: 'soil_polygons',
      archivePath: archivePath,
    ),
  ];

  @override
  Future<void> close() async {}
}
