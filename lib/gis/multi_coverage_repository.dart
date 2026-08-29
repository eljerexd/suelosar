import 'dart:math' as math;

import 'package:flutter/foundation.dart';

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
    Future<bool> Function(MapCoverage coverage)? isCoverageAvailable,
    GisRepository Function(MapCoverage coverage)? repositoryBuilder,
  }) : assert(coverages.isNotEmpty),
       assert(coverages.any((coverage) => coverage.id == defaultCoverageId)),
       _isCoverageAvailable = isCoverageAvailable,
       _repositoryBuilder = repositoryBuilder;

  final List<MapCoverage> coverages;
  final String defaultCoverageId;

  // Fase 11B: both default to "always true"/"always the existing
  // .fromAsset construction" when not supplied, so every pre-existing
  // caller (Buenos Aires, tests) is byte-for-byte unaffected — only
  // GisMapScreen's real construction site passes overrides, and only for
  // the Santa Fe coverage specifically.
  final Future<bool> Function(MapCoverage coverage)? _isCoverageAvailable;
  final GisRepository Function(MapCoverage coverage)? _repositoryBuilder;

  final Map<String, GisRepository> _repositoryByCoverageId = {};

  /// Coverages confirmed available as of the last [initialize] or
  /// [markCoverageAvailable] call. A coverage absent from here is never
  /// queried — see the [loadTile] guard below — so a not-yet-downloaded
  /// Santa Fe never attempts to open a PMTiles archive that doesn't exist.
  final Set<String> _availableCoverageIds = {};

  /// Bugfix (race on cold start): the map engine can call [loadTile]
  /// before the caller's own `await initialize()` has resolved — e.g.
  /// FlutterMap's `onReady` firing while `GisMapScreen._initializeArchive`
  /// is still awaiting this same call. Before this fix, that early
  /// [loadTile] saw an empty [_availableCoverageIds] (not populated yet)
  /// and returned an empty layer immediately — and because that empty
  /// result's tile coordinates got recorded as "already loaded", the
  /// *correct* reload that runs once [initialize] actually finishes was
  /// silently skipped (same coordinates, nothing looked stale), leaving
  /// Buenos Aires permanently without polygons on a slow first run (the
  /// real culprit: copying its ~194MB archive to disk on first launch).
  /// Tracking the in-flight [Future] here lets [loadTile] await it instead
  /// of racing ahead of it.
  Future<GisArchiveInfo>? _initializationFuture;

  GisRepository _repositoryFor(MapCoverage coverage) {
    return _repositoryByCoverageId.putIfAbsent(
      coverage.id,
      () =>
          _repositoryBuilder?.call(coverage) ??
          PmTilesGisRepository.fromAsset(
            assetPath: coverage.config.pmtilesAsset,
            versionAssetPath: coverage.config.pmtilesVersionAsset,
            layerName: coverage.config.pmtilesLayerName,
          ),
    );
  }

  MapCoverage get _defaultCoverage =>
      coverages.firstWhere((coverage) => coverage.id == defaultCoverageId);

  @override
  Future<GisArchiveInfo> initialize() {
    return _initializationFuture ??= _doInitialize();
  }

  Future<GisArchiveInfo> _doInitialize() async {
    final available = <MapCoverage>[];
    for (final coverage in coverages) {
      final isAvailable =
          _isCoverageAvailable == null || await _isCoverageAvailable(coverage);
      if (isAvailable) available.add(coverage);
    }
    // The default coverage (Buenos Aires) must always be usable — nothing
    // in this phase makes it conditional, so this can only trip if a future
    // caller misconfigures availability for it.
    assert(available.any((coverage) => coverage.id == defaultCoverageId));
    _availableCoverageIds
      ..clear()
      ..addAll(available.map((coverage) => coverage.id));

    final infos = await Future.wait(
      available.map((coverage) => _repositoryFor(coverage).initialize()),
    );

    // Zoom bounds cover every coverage, so panning into any of them stays
    // navigable. Center stays the default coverage's (Buenos Aires,
    // Parte 8: "no cambiar el inicio de la aplicación en esta fase") —
    // never an average/merge of the coverages' centers, which wouldn't
    // usefully point at either.
    final defaultIndex = available.indexOf(_defaultCoverage);
    return GisArchiveInfo(
      minZoom: infos.map((info) => info.minZoom).reduce(math.min),
      maxZoom: infos.map((info) => info.maxZoom).reduce(math.max),
      centerLatitude: infos[defaultIndex].centerLatitude,
      centerLongitude: infos[defaultIndex].centerLongitude,
    );
  }

  /// Called once a previously-unavailable coverage (Santa Fe, after its
  /// on-demand download completes) becomes usable. Initializes its
  /// repository and adds it to the active set so the next [loadTile] call
  /// actually queries it — a no-op if it's already available.
  Future<void> markCoverageAvailable(String coverageId) async {
    if (_availableCoverageIds.contains(coverageId)) return;
    final coverage = coverages.firstWhere((c) => c.id == coverageId);
    await _repositoryFor(coverage).initialize();
    _availableCoverageIds.add(coverageId);
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    // See _initializationFuture's doc comment: wait for an in-flight
    // initialize() rather than reading _availableCoverageIds while it's
    // still empty/stale.
    final initializationFuture = _initializationFuture;
    if (initializationFuture != null) {
      await initializationFuture;
    }

    final tileBounds = _tileGeoBounds(coordinates);
    final relevant = coverages
        .where(
          (coverage) =>
              coverage.bounds.intersects(tileBounds) &&
              _availableCoverageIds.contains(coverage.id),
        )
        .toList(growable: false);

    if (relevant.isEmpty) {
      return GisLayer(id: _tileLayerId(coordinates), name: '', features: const []);
    }

    // Bugfix (aislar fallos entre coberturas): each coverage's fetch is
    // isolated in its own try/catch rather than one shared Future.wait —
    // GeoBounds rectangles genuinely overlap between provinces (see this
    // class's doc comment), so a tile near that overlap can have both
    // Buenos Aires and Santa Fe as "relevant". Before this fix, one
    // coverage failing (e.g. a Santa Fe archive that turned out unusable
    // despite being marked available) rejected the whole Future.wait and
    // took Buenos Aires down with it, even though BA's own fetch would
    // have succeeded on its own. Only surfaces as an error when every
    // relevant coverage failed for this tile — a partial result is not an
    // error.
    Object? lastError;
    StackTrace? lastStackTrace;
    final results = await Future.wait(
      relevant.map((coverage) async {
        try {
          return await _repositoryFor(coverage).loadTile(coordinates);
        } catch (error, stackTrace) {
          lastError = error;
          lastStackTrace = stackTrace;
          debugPrint(
            'MultiCoverageRepository: coverage "${coverage.id}" failed to '
            'load tile ${coordinates.zoom}/${coordinates.x}/${coordinates.y} '
            '— skipping it for this tile: $error',
          );
          return null;
        }
      }),
    );

    final succeededCoverages = <MapCoverage>[];
    final succeededLayers = <GisLayer>[];
    for (var i = 0; i < relevant.length; i++) {
      final layer = results[i];
      if (layer != null) {
        succeededCoverages.add(relevant[i]);
        succeededLayers.add(layer);
      }
    }

    if (succeededLayers.isEmpty) {
      Error.throwWithStackTrace(lastError!, lastStackTrace!);
    }

    final features = <GisFeature>[];
    for (var i = 0; i < succeededCoverages.length; i++) {
      final coverage = succeededCoverages[i];
      for (final feature in succeededLayers[i].features) {
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
      name: succeededLayers.first.name,
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
