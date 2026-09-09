import '../gis/series_resolver.dart' show SeriesPdfLocation;
import '../repositories/santa_fe_series_repository.dart';
import 'soil_map.dart';

/// Which province a [SoilCard] belongs to. Purely a catalog label for the
/// "Memorias descriptivas" screen's filter — unrelated to `ProvinceConfig`
/// (the GIS map's own province switch) and never read by the GIS code.
enum SoilCardProvince { buenosAires, santaFe }

/// One entry in the unified "Memorias descriptivas" catalog (Santa Fe Fase
/// 7): a descriptive PDF sheet, regardless of whether it lives in its own
/// file (Buenos Aires, [SoilMap]) or as a page range inside one consolidated
/// PDF (Santa Fe, [SantaFeSeriesEntry]) — see [SeriesPdfLocation], already
/// used for the same BA/SF split in `GisMapScreen`'s series-to-PDF lookup.
class SoilCard {
  const SoilCard({
    required this.title,
    required this.province,
    required this.favoriteIdentifier,
    required this.location,
  });

  /// Series/carta display name — always the real name (e.g. "Río Salado"),
  /// never a raw series code, for both provinces.
  final String title;

  final SoilCardProvince province;

  /// Stable key for [PdfSoilSheetFavorite.pdfIdentifier] persistence/dedup.
  /// Buenos Aires reuses its existing bare PDF filename unchanged (e.g.
  /// `"Junín.pdf"`), so favorites saved before this Fase keep matching.
  /// Santa Fe uses [santaFeFavoriteIdentifierPrefix] + series code (e.g.
  /// `"santa_fe:RSA"`) — every Santa Fe series shares the same consolidated
  /// PDF asset path, so the filename alone can't tell them apart, and some
  /// series names collide with Buenos Aires ones (e.g. both catalogs have
  /// an "Aarón Castellanos"), so the identifiers must not collide either.
  final String favoriteIdentifier;

  /// Where the descriptive PDF material lives: [SeriesPdfLocation.assetPath]
  /// alone for Buenos Aires, plus [SeriesPdfLocation.startPage]/[endPage]
  /// for Santa Fe's page range inside the consolidated PDF.
  final SeriesPdfLocation location;

  /// Prefix marking a [favoriteIdentifier] as a Santa Fe series code rather
  /// than a Buenos Aires PDF filename. Read back by `FavoritesScreen` to
  /// resolve a saved favorite to its page range instead of a bare asset.
  static const String santaFeFavoriteIdentifierPrefix = 'santa_fe:';

  factory SoilCard.buenosAires(SoilMap soilMap) => SoilCard(
    title: soilMap.name,
    province: SoilCardProvince.buenosAires,
    favoriteIdentifier: soilMap.pdf,
    location: SeriesPdfLocation(assetPath: soilMap.assetPath),
  );

  factory SoilCard.santaFe(SantaFeSeriesEntry entry, {required String pdfAsset}) =>
      SoilCard(
        title: entry.name,
        province: SoilCardProvince.santaFe,
        favoriteIdentifier: '$santaFeFavoriteIdentifierPrefix${entry.code}',
        location: SeriesPdfLocation(
          assetPath: pdfAsset,
          startPage: entry.startPage,
          endPage: entry.endPage,
        ),
      );
}
