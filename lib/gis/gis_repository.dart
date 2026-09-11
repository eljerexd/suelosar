import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pmtiles/pmtiles.dart';
import 'package:vector_tile/vector_tile.dart' as vector_tile;

import 'gis_feature.dart';
import 'gis_layer.dart';
// TEMPORARY: remove together with every PmtilesDiagnostics call once the
// real-Play PMTiles investigation is closed.
import 'pmtiles_diagnostics.dart';

/// Storage-independent access to spatial map tiles.
abstract interface class GisRepository {
  Future<GisArchiveInfo> initialize();

  Future<GisLayer> loadTile(GisTileCoordinates coordinates);

  Future<void> close();
}

/// Snapshot of the work avoided by the in-memory PMTiles cache.
class GisTileCacheMetrics {
  const GisTileCacheMetrics({
    required this.cachedTileCount,
    required this.maximumCachedTileCount,
    required this.decodedTileCount,
    required this.cacheHitCount,
    required this.coalescedRequestCount,
    required this.totalDecodeDuration,
  });

  final int cachedTileCount;
  final int maximumCachedTileCount;
  final int decodedTileCount;
  final int cacheHitCount;
  final int coalescedRequestCount;
  final Duration totalDecodeDuration;
}

/// Reads vector features and their attributes from a local PMTiles archive.
class PmTilesGisRepository implements GisRepository {
  PmTilesGisRepository._({
    required this._archiveFileResolver,
    required this.layerName,
    required this.maxCacheEntries,
  });

  static const int defaultMaxCacheEntries = 128;

  factory PmTilesGisRepository.fromFile({
    required File archiveFile,
    required String layerName,
    int maxCacheEntries = defaultMaxCacheEntries,
  }) {
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(
        maxCacheEntries,
        'maxCacheEntries',
        'Must be greater than zero.',
      );
    }
    return PmTilesGisRepository._(
      archiveFileResolver: () async => archiveFile,
      layerName: layerName,
      maxCacheEntries: maxCacheEntries,
    );
  }

  factory PmTilesGisRepository.fromAsset({
    required String assetPath,
    required String versionAssetPath,
    required String layerName,
    AssetBundle? assetBundle,
    Future<Directory> Function()? supportDirectoryProvider,
    int maxCacheEntries = defaultMaxCacheEntries,
  }) {
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(
        maxCacheEntries,
        'maxCacheEntries',
        'Must be greater than zero.',
      );
    }
    final bundle = assetBundle ?? rootBundle;
    final directoryProvider =
        supportDirectoryProvider ?? getApplicationSupportDirectory;

    return PmTilesGisRepository._(
      archiveFileResolver: () => _prepareAssetArchive(
        assetBundle: bundle,
        assetPath: assetPath,
        versionAssetPath: versionAssetPath,
        supportDirectoryProvider: directoryProvider,
      ),
      layerName: layerName,
      maxCacheEntries: maxCacheEntries,
    );
  }

  final Future<File> Function() _archiveFileResolver;
  final String layerName;
  final int maxCacheEntries;

  final LinkedHashMap<GisTileCoordinates, GisLayer> _tileCache =
      LinkedHashMap<GisTileCoordinates, GisLayer>();
  final Map<GisTileCoordinates, Future<GisLayer>> _pendingTiles =
      <GisTileCoordinates, Future<GisLayer>>{};

  Future<GisArchiveInfo>? _initialization;
  PmTilesArchive? _archive;
  int _decodedTileCount = 0;
  int _cacheHitCount = 0;
  int _coalescedRequestCount = 0;
  Duration _totalDecodeDuration = Duration.zero;

  GisTileCacheMetrics get cacheMetrics => GisTileCacheMetrics(
    cachedTileCount: _tileCache.length,
    maximumCachedTileCount: maxCacheEntries,
    decodedTileCount: _decodedTileCount,
    cacheHitCount: _cacheHitCount,
    coalescedRequestCount: _coalescedRequestCount,
    totalDecodeDuration: _totalDecodeDuration,
  );

  @override
  Future<GisArchiveInfo> initialize() {
    // Bugfix (aislar fallos entre coberturas): only a successful open is
    // cached. Previously a failed attempt was memoized too, so a coverage
    // that started out unusable (e.g. Santa Fe before its on-demand
    // archive is genuinely available) stayed permanently broken for the
    // rest of the app session even after it became usable — every
    // subsequent initialize() call just replayed the same cached
    // rejection instead of retrying. Clearing it on failure lets the next
    // call open the archive fresh.
    return _initialization ??= _openArchive().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _initialization = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    final info = await initialize();
    if (coordinates.zoom < info.minZoom || coordinates.zoom > info.maxZoom) {
      return _emptyLayer(coordinates);
    }

    final cached = _tileCache.remove(coordinates);
    if (cached != null) {
      _tileCache[coordinates] = cached;
      _cacheHitCount++;
      return cached;
    }

    final pending = _pendingTiles[coordinates];
    if (pending != null) {
      _coalescedRequestCount++;
      return pending;
    }

    final loading = _readAndDecodeTile(coordinates);
    _pendingTiles[coordinates] = loading;

    try {
      final layer = await loading;
      _tileCache.remove(coordinates);
      _tileCache[coordinates] = layer;
      while (_tileCache.length > maxCacheEntries) {
        _tileCache.remove(_tileCache.keys.first);
      }
      return layer;
    } finally {
      _pendingTiles.remove(coordinates);
    }
  }

  @override
  Future<void> close() async {
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {
        // Initialization already reports its own failure to the caller.
      }
    }

    final pending = _pendingTiles.values.toList(growable: false);
    if (pending.isNotEmpty) {
      await Future.wait(pending).catchError((_) => <GisLayer>[]);
    }

    _pendingTiles.clear();
    _tileCache.clear();
    final archive = _archive;
    _archive = null;
    _initialization = null;
    await archive?.close();
  }

  Future<GisArchiveInfo> _openArchive() async {
    final archiveFile = await _archiveFileResolver();
    final archive = await PmTilesArchive.fromFile(archiveFile);

    if (archive.tileType != TileType.mvt) {
      await archive.close();
      throw StateError('The PMTiles archive must contain MVT vector tiles.');
    }

    _archive = archive;
    return GisArchiveInfo(
      minZoom: archive.minZoom,
      maxZoom: archive.maxZoom,
      centerLatitude: archive.centerPosition.latitude,
      centerLongitude: archive.centerPosition.longitude,
    );
  }

  Future<GisLayer> _readAndDecodeTile(GisTileCoordinates coordinates) async {
    final archive = _archive;
    if (archive == null) {
      throw StateError('The PMTiles archive is not initialized.');
    }

    try {
      final tileId = ZXY(
        coordinates.zoom,
        coordinates.x,
        coordinates.y,
      ).toTileId();
      final tile = await _readPmTilesTile(archive, tileId);
      final request = _TileDecodeRequest(
        bytes: TransferableTypedData.fromList([
          Uint8List.fromList(tile.bytes()),
        ]),
        coordinates: coordinates,
        layerName: layerName,
      );
      final stopwatch = Stopwatch()..start();
      final layer = await Isolate.run(
        () => _decodeVectorTile(request),
        debugName:
            'pmtiles-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
      );
      stopwatch.stop();

      _decodedTileCount++;
      _totalDecodeDuration += stopwatch.elapsed;
      return layer;
    } on TileNotFoundException {
      return _emptyLayer(coordinates);
    }
  }

  GisLayer _emptyLayer(GisTileCoordinates coordinates) {
    return GisLayer(
      id: _tileLayerId(coordinates),
      name: layerName,
      features: const <GisFeature>[],
    );
  }

  String _tileLayerId(GisTileCoordinates coordinates) {
    return '$layerName-${coordinates.zoom}-${coordinates.x}-${coordinates.y}';
  }

  static Future<File> _prepareAssetArchive({
    required AssetBundle assetBundle,
    required String assetPath,
    required String versionAssetPath,
    required Future<Directory> Function() supportDirectoryProvider,
  }) async {
    // TEMPORARY (real-Play investigation): this is the exact read that has to
    // succeed for a province to render, and today its failure is invisible —
    // the caller turns any exception into "no polygons" with nothing logged.
    PmtilesDiagnostics.log('archive: loadString start $versionAssetPath');
    final String version;
    try {
      version = (await assetBundle.loadString(versionAssetPath)).trim();
    } catch (error) {
      PmtilesDiagnostics.log(
        'archive: loadString FAILED $versionAssetPath '
        '${error.runtimeType}: $error '
        '| native probe: ${await PmtilesDiagnostics.probeAsset('flutter_assets/$versionAssetPath')}',
      );
      rethrow;
    }
    PmtilesDiagnostics.log('archive: loadString ok, version=$version');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw const FormatException('Invalid PMTiles version hash.');
    }

    final supportDirectory = await supportDirectoryProvider();
    final mapDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}suelosar_maps',
    );
    await mapDirectory.create(recursive: true);

    // Derived from assetPath (not hardcoded to "soil_polygons") so two
    // provinces' archives never collide in the on-disk cache — e.g.
    // "assets/maps/santa_fe_soil_polygons.pmtiles" and
    // "assets/maps/soil_polygons.pmtiles" now cache under different
    // filenames instead of both racing for "soil_polygons-<hash>.pmtiles".
    final assetStem = assetPath.split('/').last.replaceAll(
      RegExp(r'\.pmtiles$'),
      '',
    );
    final target = File(
      '${mapDirectory.path}${Platform.pathSeparator}'
      '$assetStem-$version.pmtiles',
    );
    if (await target.exists()) {
      if (await target.length() > 127) {
        PmtilesDiagnostics.log(
          'archive: reusing cached ${target.path} (${await target.length()} bytes)',
        );
        return target;
      }
      await target.delete();
    }

    final temporary = File('${target.path}.tmp');
    if (await temporary.exists()) {
      await temporary.delete();
    }

    // TEMPORARY (real-Play investigation): the ~151 MB read. Timed and
    // reported because a failure here leaves the province marked available
    // with no polygons on screen — exactly the reported Buenos Aires symptom.
    PmtilesDiagnostics.log(
      'archive: rootBundle.load start $assetPath '
      '| native probe: ${await PmtilesDiagnostics.probeAsset('flutter_assets/$assetPath')}',
    );
    final loadWatch = Stopwatch()..start();
    final ByteData data;
    try {
      data = await assetBundle.load(assetPath);
    } catch (error) {
      PmtilesDiagnostics.log(
        'archive: rootBundle.load FAILED $assetPath after '
        '${loadWatch.elapsedMilliseconds}ms ${error.runtimeType}: $error',
      );
      rethrow;
    }
    PmtilesDiagnostics.log(
      'archive: rootBundle.load ok $assetPath '
      'bytes=${data.lengthInBytes} in ${loadWatch.elapsedMilliseconds}ms',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final output = await temporary.open(mode: FileMode.write);

    try {
      const chunkSize = 4 * 1024 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = math.min(offset + chunkSize, bytes.length);
        await output.writeFrom(bytes, offset, end);
      }
      await output.flush();
    } finally {
      await output.close();
    }

    await temporary.rename(target.path);
    await _removeOldArchives(mapDirectory, assetStem, target.path);
    return target;
  }

  /// Deletes stale cached versions of *this* province's archive only —
  /// matched by [assetStem] (e.g. "soil_polygons" or
  /// "santa_fe_soil_polygons") — so caching one province's PMTiles never
  /// evicts another province's already-cached archive from the same shared
  /// [mapDirectory].
  static Future<void> _removeOldArchives(
    Directory mapDirectory,
    String assetStem,
    String currentPath,
  ) async {
    final stalePrefix = '$assetStem-';
    await for (final entity in mapDirectory.list()) {
      final filename = entity.path.split(Platform.pathSeparator).last;
      if (entity is! File ||
          entity.path == currentPath ||
          !filename.startsWith(stalePrefix) ||
          !filename.endsWith('.pmtiles')) {
        continue;
      }
      await entity.delete();
    }
  }
}

/// Whether [assetPath]'s local cached copy (the file
/// [PmTilesGisRepository.fromAsset] opens, written by
/// `_prepareAssetArchive` under `suelosar_maps`) already exists on disk —
/// checked WITHOUT creating one if it's missing, unlike `initialize()`,
/// which recreates a missing copy from the bundled asset the moment it's
/// called.
///
/// Fase 11D bugfix: `MultiCoverageRepository`'s availability check
/// previously trusted every non-Santa-Fe coverage (Buenos Aires) as
/// always available, since historically there was no way to remove its
/// local copy at all. Now that Configuración's provincial maps manager
/// can delete it, "available" has to mean "the file is actually there",
/// checked *before* building/initializing a repository for it — never by
/// calling `initialize()` itself and observing whether it throws, since
/// that call is exactly what would silently recreate the file from the
/// bundled asset and defeat the deletion.
Future<bool> pmtilesAssetIsCachedLocally({
  required String assetPath,
  Future<Directory> Function()? supportDirectoryProvider,
}) async {
  final directoryProvider =
      supportDirectoryProvider ?? getApplicationSupportDirectory;
  final supportDirectory = await directoryProvider();
  final mapDirectory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}suelosar_maps',
  );
  if (!await mapDirectory.exists()) return false;

  final assetStem = assetPath.split('/').last.replaceAll(
    RegExp(r'\.pmtiles$'),
    '',
  );
  await for (final entity in mapDirectory.list()) {
    if (entity is! File) continue;
    final filename = entity.uri.pathSegments.last;
    if (!filename.startsWith('$assetStem-') ||
        !filename.endsWith('.pmtiles')) {
      continue;
    }
    // Matches `_prepareAssetArchive`'s own validity check — an empty or
    // truncated file (e.g. the app was killed mid-copy) doesn't count.
    if (await entity.length() > 127) return true;
  }
  return false;
}

class _TileDecodeRequest {
  const _TileDecodeRequest({
    required this.bytes,
    required this.coordinates,
    required this.layerName,
  });

  final TransferableTypedData bytes;
  final GisTileCoordinates coordinates;
  final String layerName;
}

GisLayer _decodeVectorTile(_TileDecodeRequest request) {
  if (!kProfileMode) {
    return _decodeVectorTileContents(request);
  }
  return developer.Timeline.timeSync(
    'SuelosAR.MVTDecode',
    () => _decodeVectorTileContents(request),
  );
}

GisLayer _decodeVectorTileContents(_TileDecodeRequest request) {
  final bytes = request.bytes.materialize().asUint8List();
  final vectorTile = vector_tile.VectorTile.fromBytes(bytes: bytes);
  final sourceLayer = _findLayer(vectorTile, request.layerName);
  if (sourceLayer == null) {
    return _emptyDecodedLayer(request.coordinates, request.layerName);
  }

  final features = <GisFeature>[];
  for (var index = 0; index < sourceLayer.features.length; index++) {
    final feature = sourceLayer.features[index];
    if (feature.type != vector_tile.VectorTileGeomType.POLYGON) {
      continue;
    }

    final polygons = feature.decodePolygon();
    if (polygons.isEmpty) {
      continue;
    }

    final properties = _decodeProperties(feature);
    final projectedPolygons = polygons
        .map(
          (polygon) =>
              _projectPolygon(polygon, sourceLayer.extent, request.coordinates),
        )
        .toList(growable: false);
    final featureId = feature.id.toString() == '0'
        ? '${request.coordinates.zoom}/${request.coordinates.x}/'
              '${request.coordinates.y}/$index'
        : feature.id.toString();

    features.add(
      GisFeature(
        id: featureId,
        geometry: GisGeometry(
          type: projectedPolygons.length == 1 ? 'Polygon' : 'MultiPolygon',
          coordinates: projectedPolygons.length == 1
              ? projectedPolygons.first
              : projectedPolygons,
        ),
        properties: properties,
        locality: _readString(
          properties['locality'] ?? properties['localidad'],
        ),
        soilMapId: _readInt(
          properties['soilMapId'] ?? properties['soil_map_id'],
        ),
      ),
    );
  }

  return GisLayer(
    id: _tileLayerId(request.coordinates, request.layerName),
    name: request.layerName,
    features: List<GisFeature>.unmodifiable(features),
    properties: {
      'zoom': request.coordinates.zoom,
      'x': request.coordinates.x,
      'y': request.coordinates.y,
    },
  );
}

Future<Tile> _readPmTilesTile(PmTilesArchive archive, int tileId) async {
  if (!kProfileMode) {
    return archive.tile(tileId);
  }

  final task = developer.TimelineTask()..start('SuelosAR.PMTilesRead');
  try {
    return await archive.tile(tileId);
  } finally {
    task.finish();
  }
}

vector_tile.VectorTileLayer? _findLayer(
  vector_tile.VectorTile tile,
  String layerName,
) {
  for (final layer in tile.layers) {
    if (layer.name == layerName) {
      return layer;
    }
  }
  return null;
}

Map<String, Object?> _decodeProperties(vector_tile.VectorTileFeature feature) {
  return Map<String, Object?>.unmodifiable({
    for (final entry in feature.decodeProperties().entries)
      entry.key: _decodeValue(entry.value),
  });
}

Object? _decodeValue(vector_tile.VectorTileValue value) {
  return value.dartStringValue ??
      value.dartIntValue?.toInt() ??
      value.dartDoubleValue ??
      value.dartBoolValue;
}

List<List<List<double>>> _projectPolygon(
  List<List<List<int>>> polygon,
  int extent,
  GisTileCoordinates coordinates,
) {
  return polygon
      .map(
        (ring) => ring
            .map((point) => _projectPoint(point, extent, coordinates))
            .toList(growable: false),
      )
      .toList(growable: false);
}

List<double> _projectPoint(
  List<int> point,
  int extent,
  GisTileCoordinates coordinates,
) {
  final tilesAtZoom = 1 << coordinates.zoom;
  final worldX = coordinates.x + (point[0] / extent);
  final worldY = coordinates.y + (point[1] / extent);
  final longitude = (worldX / tilesAtZoom * 360) - 180;
  final mercatorY = math.pi * (1 - (2 * worldY / tilesAtZoom));
  final hyperbolicSine = (math.exp(mercatorY) - math.exp(-mercatorY)) / 2;
  final latitude = math.atan(hyperbolicSine) * 180 / math.pi;

  return <double>[longitude, latitude];
}

GisLayer _emptyDecodedLayer(GisTileCoordinates coordinates, String layerName) {
  return GisLayer(
    id: _tileLayerId(coordinates, layerName),
    name: layerName,
    features: const <GisFeature>[],
  );
}

String _tileLayerId(GisTileCoordinates coordinates, String layerName) {
  return '$layerName-${coordinates.zoom}-${coordinates.x}-${coordinates.y}';
}

String _readString(Object? value) {
  return value?.toString() ?? '';
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
