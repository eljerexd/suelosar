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
    this.downloadBannerAnchor,
    this.pmtilesDownloadSizeBytes,
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

  /// A real point inside the province, used only to anchor the on-demand
  /// download banner/notice (Fase 11C/12A) — null for a coverage that isn't
  /// delivered on demand (see [MapCoverage.onDemandDelivery]). See
  /// [santaFe]'s value for the full reasoning on why a real, well-known,
  /// roughly-central town is used instead of the archive's data-derived
  /// center or the boundary polygon's centroid.
  final LatLng? downloadBannerAnchor;

  /// On-disk size of [pmtilesAsset], in bytes — what the on-demand
  /// download card shows before the archive exists on the device.
  ///
  /// Declared here rather than measured because it has to be known
  /// *before* downloading: on Android the archive ships as a deferred
  /// component, so there is no local file to read a length from until
  /// the download this number is describing has already happened.
  ///
  /// Must be re-read from the real asset whenever that asset is
  /// regenerated (`tool/optimize_buenos_aires_pmtiles.dart`), alongside
  /// its `.sha256` companion. Null for a province whose size is not
  /// known — the card then simply omits the size line rather than
  /// showing a guess.
  final int? pmtilesDownloadSizeBytes;

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
    // Bolívar — a real, well-known town sitting close to the geographic
    // middle of the province, the same reasoning Santa Fe's anchor uses
    // below (Fase 12A: Buenos Aires becomes on-demand too).
    downloadBannerAnchor: const LatLng(-36.2333, -61.1167),
    // assets/maps/soil_polygons.pmtiles — 158,646,380 bytes (151 MB),
    // the optimized archive tracked by soil_polygons.pmtiles.sha256.
    pmtilesDownloadSizeBytes: 158646380,
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
      // Rafaela — a well-known city that sits close to the geographic
      // middle of the province (roughly equidistant from the northern
      // Chaco border and the southern Rosario/Buenos Aires border), rather
      // than the PMTiles archive's data-derived center (which sits far
      // enough south, near Rosario/Casilda, to read as "next to Buenos
      // Aires") or the area centroid of the boundary polygon (which, for
      // this province's shape — wide in the north, narrow near Rosario —
      // skews noticeably north of the visual middle). Moved here from the
      // download-banner widget itself in Fase 12A, once Buenos Aires needed
      // an equivalent anchor and this stopped being Santa-Fe-only data.
      downloadBannerAnchor: const LatLng(-31.2503, -61.4867),
      // assets/maps/santa_fe_soil_polygons.pmtiles — 65,985,455 bytes
      // (63 MB), tracked by santa_fe_soil_polygons.pmtiles.sha256.
      pmtilesDownloadSizeBytes: 65985455,
    );
  }
}
