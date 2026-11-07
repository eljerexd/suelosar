/// A local vector-tile source that a native map renderer can consume without
/// copying or decoding the archive in Dart.
class GisNativeMapSource {
  const GisNativeMapSource({
    required this.id,
    required this.coverageId,
    required this.layerName,
    required this.archivePath,
    this.defaultCoverage = false,
  });

  final String id;
  final String coverageId;
  final String layerName;
  final String archivePath;
  final bool defaultCoverage;
}

/// Optional capability implemented by repositories backed by a local
/// PMTiles archive. Kept separate from [GisRepository] so test repositories
/// and other storage implementations do not need native-map concerns.
abstract interface class GisNativeMapSourceProvider {
  Future<List<GisNativeMapSource>> getNativeMapSources();
}
