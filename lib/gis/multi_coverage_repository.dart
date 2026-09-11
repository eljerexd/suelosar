import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'gis_feature.dart';
import 'gis_layer.dart';
import 'gis_repository.dart';
import 'map_coverage.dart';
// TEMPORARY: remove together with every PmtilesDiagnostics call once the
// real-Play PMTiles investigation is closed.
import 'pmtiles_diagnostics.dart';

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
    _availableCoverageIds
      ..clear()
      ..addAll(available.map((coverage) => coverage.id));

    // Fase 11D bugfix: the default coverage (Buenos Aires) used to be
    // asserted always-available here, back when there was no way to
    // remove its local copy at all. Now that Configuración's provincial
    // maps manager can delete it, every coverage — including the default
    // one — can genuinely be empty-handed, so this has to degrade
    // gracefully instead of asserting/crashing: fall back to the default
    // coverage's own placeholder info (the same one GisMapScreen already
    // shows before any real archive loads) when NOTHING is available.
    if (available.isEmpty) {
      return _defaultCoverage.config.defaultArchiveInfo;
    }

    final infos = await Future.wait(
      available.map((coverage) => _repositoryFor(coverage).initialize()),
    );

    // Zoom bounds cover every coverage, so panning into any of them stays
    // navigable. Center stays the default coverage's (Buenos Aires,
    // Parte 8: "no cambiar el inicio de la aplicación en esta fase") when
    // it's actually available; otherwise falls back to whichever coverage
    // is, so deleting the default coverage's cartography doesn't strand
    // the camera on a point with nothing left to show.
    final defaultIndex = available.indexOf(_defaultCoverage);
    final centerInfo = defaultIndex >= 0 ? infos[defaultIndex] : infos.first;
    return GisArchiveInfo(
      minZoom: infos.map((info) => info.minZoom).reduce(math.min),
      maxZoom: infos.map((info) => info.maxZoom).reduce(math.max),
      centerLatitude: centerInfo.centerLatitude,
      centerLongitude: centerInfo.centerLongitude,
    );
  }

  /// Called once a previously-unavailable coverage (Santa Fe, after its
  /// on-demand download completes; any coverage whose local PMTiles copy
  /// reappears, e.g. re-downloaded after being deleted) becomes usable.
  /// Initializes its repository and adds it to the active set so the next
  /// [loadTile] call actually queries it. Returns whether this actually
  /// changed anything — a no-op (returns `false`) if it was already
  /// available — so a caller can skip reloading tiles when nothing did.
  Future<bool> markCoverageAvailable(String coverageId) async {
    if (_availableCoverageIds.contains(coverageId)) {
      PmtilesDiagnostics.log('repo: markAvailable $coverageId (already in set)');
      return false;
    }
    final coverage = coverages.firstWhere((c) => c.id == coverageId);
    // TEMPORARY (real-Play investigation): this initialize() is what opens the
    // archive. If it throws, the coverage never joins the queried set and the
    // province silently renders nothing — the failure is otherwise unlogged.
    PmtilesDiagnostics.log('repo: initialize $coverageId start');
    try {
      final info = await _repositoryFor(coverage).initialize();
      PmtilesDiagnostics.log(
        'repo: initialize $coverageId ok '
        '(zoom ${info.minZoom}-${info.maxZoom})',
      );
    } catch (error) {
      PmtilesDiagnostics.log(
        'repo: initialize $coverageId FAILED ${error.runtimeType}: $error',
      );
      rethrow;
    }
    _availableCoverageIds.add(coverageId);
    PmtilesDiagnostics.log('repo: available set now $_availableCoverageIds');
    return true;
  }

  /// The mirror of [markCoverageAvailable] — Fase 11D bugfix. A coverage
  /// removed from Configuración's provincial maps manager (Buenos Aires
  /// today; anything else with no on-demand delivery/uninstall flow of
  /// its own, unlike Santa Fe's) must stop being queried by [loadTile]
  /// immediately, and must not keep serving tiles from a
  /// [PmTilesGisRepository] instance that was opened before its
  /// underlying file was deleted. Discards that cached instance — closing
  /// it first — rather than just forgetting about it, so a later
  /// [markCoverageAvailable] for the same id builds a fresh repository
  /// against whatever's on disk *then*, instead of reusing one whose
  /// already-open PMTiles archive handle predates the deletion. Returns
  /// whether this actually changed anything, same as
  /// [markCoverageAvailable].
  Future<bool> markCoverageUnavailable(String coverageId) async {
    if (!_availableCoverageIds.contains(coverageId)) return false;
    _availableCoverageIds.remove(coverageId);
    final repository = _repositoryByCoverageId.remove(coverageId);
    if (repository != null) {
      await repository.close();
    }
    return true;
  }

  /// TEMPORARY — caps tile chatter so the interesting lines stay findable.
  /// A pan can ask for dozens of tiles; the first few of each distinct
  /// outcome are enough to tell "nothing was queried" from "queried and
  /// empty" from "queried and rendered".
  static final _loggedTileOutcomes = <String>{};

  void _logTileOutcome(String message) {
    final key = message.replaceAll(RegExp(r'\d+'), '#');
    if (!_loggedTileOutcomes.add(key)) return;
    PmtilesDiagnostics.log(message);
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
      // TEMPORARY (real-Play investigation): answers "why are there no
      // polygons" directly — an empty layer because no available coverage
      // overlaps this tile, as opposed to a coverage that was queried and
      // came back with nothing. Throttled: loadTile runs per tile per pan.
      _logTileOutcome(
        'tile ${coordinates.zoom}/${coordinates.x}/${coordinates.y}: '
        'no relevant coverage (available=$_availableCoverageIds)',
      );
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
      PmtilesDiagnostics.log(
        'tile ${coordinates.zoom}/${coordinates.x}/${coordinates.y}: '
        'every relevant coverage failed '
        '(${relevant.map((c) => c.id).toList()}) '
        '${lastError.runtimeType}: $lastError',
      );
      Error.throwWithStackTrace(lastError!, lastStackTrace!);
    }
    _logTileOutcome(
      'tile ${coordinates.zoom}/${coordinates.x}/${coordinates.y}: '
      '${succeededCoverages.map((c) => c.id).toList()} -> '
      '${succeededLayers.fold<int>(0, (sum, l) => sum + l.features.length)} features',
    );

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
