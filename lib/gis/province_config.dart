import 'package:latlong2/latlong.dart';

import '../constants/asset_paths.dart';
import '../repositories/pdf_series_repository.dart';
import '../repositories/santa_fe_series_repository.dart';
import 'gis_layer.dart';
import 'series_resolver.dart';

/// Everything about a province's soil map that genuinely differs from
/// Buenos Aires — derived from the Fase 4A audit of `GisMapScreen`, not
/// assumed upfront. Deliberately does *not* include a `bbox`/pan-limit
/// field: no such concept exists anywhere in the current map screen (only
/// `GisArchiveInfo.minZoom/maxZoom` and an initial camera center), so
/// there's nothing real to migrate there yet.
class ProvinceConfig {
  const ProvinceConfig({
    required this.id,
    required this.pmtilesAsset,
    required this.pmtilesVersionAsset,
    required this.pmtilesLayerName,
    required this.initialCenter,
    required this.defaultArchiveInfo,
    required this.seriesResolver,
    required this.seriesNameResolver,
    this.referenceMapAsset,
    this.preloadSeriesNames,
  });

  final String id;

  final String pmtilesAsset;
  final String pmtilesVersionAsset;
  final String pmtilesLayerName;

  /// Camera position `GisMapScreen` opens on, before the real archive
  /// metadata loads. Mirrors the previous `_buenosAiresCenter` constant.
  final LatLng initialCenter;

  /// Placeholder archive info used the same way `_defaultArchiveInfo` was:
  /// a synchronous fallback for the brief window before
  /// `PmTilesGisRepository.initialize()` resolves with the real one.
  final GisArchiveInfo defaultArchiveInfo;

  /// `OfflineReferenceMapLayer`'s basemap asset. Null means "no reference
  /// basemap for this province yet" (Santa Fe, for now) — the layer must
  /// render nothing rather than fall back to Buenos Aires' basemap.
  final String? referenceMapAsset;

  /// Resolves a series to where its PDF material lives — see
  /// `series_resolver.dart` for why this is the one piece of PDF plumbing
  /// that must be province-specific.
  final SeriesResolver seriesResolver;

  /// Best-effort raw-code -> display-name resolution for `SERIE1..6`
  /// values. Identity for Buenos Aires (already real names).
  final SeriesNameResolver seriesNameResolver;

  /// Awaited once during `GisMapScreen`'s existing async init sequence, if
  /// non-null, before the first frame that could show a soil-series name —
  /// lets [seriesNameResolver] have real data ready without a visible
  /// raw-code flash. Null for provinces whose resolver needs no preload
  /// (Buenos Aires' `IdentitySeriesNameResolver`).
  final Future<void> Function()? preloadSeriesNames;

  static final ProvinceConfig buenosAires = ProvinceConfig(
    id: 'buenos_aires',
    pmtilesAsset: AssetPaths.gisPmTiles,
    pmtilesVersionAsset: AssetPaths.gisPmTilesVersion,
    pmtilesLayerName: AssetPaths.gisLayerName,
    initialCenter: const LatLng(-36.5, -60),
    defaultArchiveInfo: const GisArchiveInfo(
      minZoom: 4,
      maxZoom: 14,
      centerLatitude: -36.5,
      centerLongitude: -60,
    ),
    referenceMapAsset: AssetPaths.agronomicReferenceMap,
    seriesResolver: BuenosAiresSeriesResolver(PdfSeriesRepository()),
    seriesNameResolver: const IdentitySeriesNameResolver(),
  );

  /// Center/bounds read directly from the validated PMTiles archive's own
  /// header metadata (Fase 3 output), not estimated — see the Fase 4B
  /// report for how they were extracted.
  ///
  /// `static final` (like [buenosAires]), not a factory method — so every
  /// caller shares the same `SantaFeSeriesRepository`/name-resolver
  /// instance instead of each accidentally re-triggering its own asset load
  /// and its own unpreloaded resolver.
  static final ProvinceConfig santaFe = _buildSantaFe();

  static ProvinceConfig _buildSantaFe() {
    final repository = SantaFeSeriesRepository();
    final nameResolver = SantaFeSeriesNameResolver(repository);
    return ProvinceConfig(
      id: 'santa_fe',
      pmtilesAsset: AssetPaths.santaFeGisPmTiles,
      pmtilesVersionAsset: AssetPaths.santaFeGisPmTilesVersion,
      pmtilesLayerName: AssetPaths.gisLayerName,
      initialCenter: const LatLng(-32.389239, -61.929932),
      defaultArchiveInfo: const GisArchiveInfo(
        minZoom: 4,
        maxZoom: 14,
        centerLatitude: -32.389239,
        centerLongitude: -61.929932,
      ),
      // Fase 5: real reference basemap (IGN WFS + GeoRef Argentina,
      // clipped to Santa Fe's extent), same schema/style as Buenos Aires'.
      referenceMapAsset: AssetPaths.santaFeAgronomicReferenceMap,
      seriesResolver: SantaFeSeriesResolver(repository),
      seriesNameResolver: nameResolver,
      preloadSeriesNames: nameResolver.preload,
    );
  }
}
