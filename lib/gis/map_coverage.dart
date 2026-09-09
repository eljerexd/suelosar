import 'buenos_aires_pmtiles_delivery.dart';
import 'pmtiles_delivery.dart';
import 'province_config.dart';
import 'santa_fe_pmtiles_delivery.dart';

/// A geographic rectangle in plain lat/lon — deliberately not
/// `flutter_map`'s `LatLngBounds`, so this stays usable from
/// `gis_repository.dart`'s engine-agnostic layer (which has never imported
/// `flutter_map`) as well as from `GisMapScreen`.
class GeoBounds {
  const GeoBounds({
    required this.minLatitude,
    required this.maxLatitude,
    required this.minLongitude,
    required this.maxLongitude,
  });

  final double minLatitude;
  final double maxLatitude;
  final double minLongitude;
  final double maxLongitude;

  bool containsPoint(double latitude, double longitude) {
    return latitude >= minLatitude &&
        latitude <= maxLatitude &&
        longitude >= minLongitude &&
        longitude <= maxLongitude;
  }

  bool intersects(GeoBounds other) {
    return minLatitude <= other.maxLatitude &&
        maxLatitude >= other.minLatitude &&
        minLongitude <= other.maxLongitude &&
        maxLongitude >= other.minLongitude;
  }

  /// Matches every possible tile — used to force a single coverage to act
  /// as if it were the only one registered (see GisMapScreen's
  /// `provinceConfig` parameter), without needing a special case in
  /// MultiCoverageRepository's intersection check.
  static const GeoBounds everywhere = GeoBounds(
    minLatitude: -90,
    maxLatitude: 90,
    minLongitude: -180,
    maxLongitude: 180,
  );
}

/// One provincial map source, positioned geographically — the unit
/// `MultiCoverageRepository` composes. Wraps [ProvinceConfig] (unchanged,
/// still exactly what a single-province `GisMapScreen` needs) rather than
/// folding bounds into it, since bounds are only meaningful once more than
/// one coverage exists at a time.
class MapCoverage {
  const MapCoverage({required this.config, required this.bounds, this.onDemandDelivery});

  final ProvinceConfig config;
  final GeoBounds bounds;

  /// Non-null exactly for coverages delivered on demand via Play Feature/
  /// Asset Delivery (Santa Fe, Buenos Aires — Fase 11B/12A) rather than
  /// unconditionally bundled. Every place that used to special-case
  /// `id == 'santa_fe'` to decide "does this coverage need a download
  /// banner/manager entry/availability probe" now checks this field
  /// instead, so a coverage's on-demand-ness lives in exactly one place.
  final PmtilesDelivery? onDemandDelivery;

  String get id => config.id;

  /// Buenos Aires' real archive extent, read from its PMTiles header
  /// (Fase 6 audit) — not estimated.
  static final MapCoverage buenosAires = MapCoverage(
    config: ProvinceConfig.buenosAires,
    bounds: const GeoBounds(
      minLatitude: -39.000509,
      maxLatitude: -33.270843,
      minLongitude: -63.457031,
      maxLongitude: -56.656494,
    ),
    onDemandDelivery: BuenosAiresPmtilesDelivery.instance,
  );

  /// Santa Fe's real archive extent, read from its PMTiles header
  /// (Fase 3/6) — not estimated.
  static final MapCoverage santaFe = MapCoverage(
    config: ProvinceConfig.santaFe,
    bounds: const GeoBounds(
      minLatitude: -34.452218,
      maxLatitude: -27.994401,
      minLongitude: -62.885742,
      maxLongitude: -58.831787,
    ),
    onDemandDelivery: SantaFePmtilesDelivery.instance,
  );

  /// Every coverage registered so far. Buenos Aires stays first — several
  /// call sites treat the first entry as the default/initial coverage
  /// (Fase 6 Parte 8: the app must keep opening on Buenos Aires).
  static final List<MapCoverage> all = [buenosAires, santaFe];
}
