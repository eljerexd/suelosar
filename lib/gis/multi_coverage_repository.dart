import 'dart:math' as math;

import 'gis_feature.dart';
import 'gis_layer.dart';
import 'gis_repository.dart';
import 'map_coverage.dart';

/// Composes several per-province [PmTilesGisRepository] instances behind
/// the single [GisRepository] interface `GisMapScreen` already talks to —
/// Fase 6, Parte 4/5. Does not replace or modify [PmTilesGisRepository]:
/// each coverage gets its own instance, with its own existing LRU tile
/// cache, completely unchanged. This class only decides *which* archives a
/// given tile needs to be read from, and merges their results.
///
/// A tile coordinate is a global slippy-map address — it has a real
/// geographic bounds independent of any province. For each requested tile,
/// only the coverages whose [MapCoverage.bounds] actually overlaps that
/// tile's bounds are queried at all, so an interior Buenos Aires tile never
/// touches the Santa Fe archive (or vice versa) — no wasted PMTiles reads,
/// no wasted decoding. A tile straddling both extents (Parte 4's "zona
/// dentro de más de una cobertura") queries both and merges their features.
class MultiCoverageRepository implements GisRepository {
  MultiCoverageRepository({
    required this.coverages,
    required this.defaultCoverageId,
  }) : assert(coverages.isNotEmpty),
       assert(coverages.any((coverage) => coverage.id == defaultCoverageId));

  final List<MapCoverage> coverages;
  final String defaultCoverageId;

  final Map<String, GisRepository> _repositoryByCoverageId = {};

  GisRepository _repositoryFor(MapCoverage coverage) {
    return _repositoryByCoverageId.putIfAbsent(
      coverage.id,
      () => PmTilesGisRepository.fromAsset(
        assetPath: coverage.config.pmtilesAsset,
        versionAssetPath: coverage.config.pmtilesVersionAsset,
        layerName: coverage.config.pmtilesLayerName,
      ),
    );
  }

  MapCoverage get _defaultCoverage =>
      coverages.firstWhere((coverage) => coverage.id == defaultCoverageId);

  @override
  Future<GisArchiveInfo> initialize() async {
    final infos = await Future.wait(
      coverages.map((coverage) => _repositoryFor(coverage).initialize()),
    );

    // Zoom bounds cover every coverage, so panning into any of them stays
    // navigable. Center stays the default coverage's (Buenos Aires,
    // Parte 8: "no cambiar el inicio de la aplicación en esta fase") —
    // never an average/merge of the coverages' centers, which wouldn't
    // usefully point at either.
    final defaultIndex = coverages.indexOf(_defaultCoverage);
    return GisArchiveInfo(
      minZoom: infos.map((info) => info.minZoom).reduce(math.min),
      maxZoom: infos.map((info) => info.maxZoom).reduce(math.max),
      centerLatitude: infos[defaultIndex].centerLatitude,
      centerLongitude: infos[defaultIndex].centerLongitude,
    );
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    final tileBounds = _tileGeoBounds(coordinates);
    final relevant = coverages
        .where((coverage) => coverage.bounds.intersects(tileBounds))
        .toList(growable: false);

    if (relevant.isEmpty) {
      return GisLayer(id: _tileLayerId(coordinates), name: '', features: const []);
    }

    final layers = await Future.wait(
      relevant.map((coverage) => _repositoryFor(coverage).loadTile(coordinates)),
    );

    final features = <GisFeature>[];
    for (var i = 0; i < relevant.length; i++) {
      final coverage = relevant[i];
      for (final feature in layers[i].features) {
        features.add(
          // Buenos Aires (the default coverage) keeps its feature ids
          // exactly as PmTilesGisRepository already issues them — so
          // existing favorites/selection state saved before Fase 6 still
          // match. Only non-default coverages get an id prefix, which
          // also makes coverageForFeatureId's lookup unambiguous.
          coverage.id == defaultCoverageId
              ? feature
              : GisFeature(
                  id: '${coverage.id}:${feature.id}',
                  geometry: feature.geometry,
                  properties: feature.properties,
                  locality: feature.locality,
                  soilMapId: feature.soilMapId,
                ),
        );
      }
    }

    return GisLayer(
      id: _tileLayerId(coordinates),
      name: layers.first.name,
      features: List<GisFeature>.unmodifiable(features),
    );
  }

  @override
  Future<void> close() async {
    for (final repository in _repositoryByCoverageId.values) {
      await repository.close();
    }
  }

  /// Which [MapCoverage] a feature id (as returned by [loadTile]) belongs
  /// to — Fase 6 Parte 6: the selection/PDF flow reads this to know whose
  /// [MapCoverage.config] (series resolver, name resolver) applies to a
  /// tapped feature. Unprefixed ids (Buenos Aires, or anything predating
  /// Fase 6) resolve to [defaultCoverageId].
  MapCoverage coverageForFeatureId(String featureId) {
    final separator = featureId.indexOf(':');
    if (separator != -1) {
      final coverageId = featureId.substring(0, separator);
      for (final coverage in coverages) {
        if (coverage.id == coverageId) return coverage;
      }
    }
    return _defaultCoverage;
  }

  String _tileLayerId(GisTileCoordinates coordinates) {
    return 'multi-${coordinates.zoom}-${coordinates.x}-${coordinates.y}';
  }
}

/// Standard slippy-map tile -> geographic bounds (Web Mercator), the exact
/// inverse of the point-projection math `_projectPoint` already uses in
/// gis_repository.dart to go the other way.
GeoBounds _tileGeoBounds(GisTileCoordinates coordinates) {
  final tilesAtZoom = 1 << coordinates.zoom;

  double longitudeAt(int x) => x / tilesAtZoom * 360 - 180;
  double latitudeAt(int y) {
    final mercatorY = math.pi * (1 - 2 * y / tilesAtZoom);
    final hyperbolicSine = (math.exp(mercatorY) - math.exp(-mercatorY)) / 2;
    return math.atan(hyperbolicSine) * 180 / math.pi;
  }

  return GeoBounds(
    minLongitude: longitudeAt(coordinates.x),
    maxLongitude: longitudeAt(coordinates.x + 1),
    // y grows downward (south), so y+1 is the southern edge.
    minLatitude: latitudeAt(coordinates.y + 1),
    maxLatitude: latitudeAt(coordinates.y),
  );
}
