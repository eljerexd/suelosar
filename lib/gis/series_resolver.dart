import '../repositories/pdf_series_repository.dart';
import '../repositories/santa_fe_series_repository.dart';
import 'gis_soil_series.dart';

/// Where a [GisSoilSeries]'s descriptive PDF material lives, resolved by a
/// [SeriesResolver]. [startPage]/[endPage] are null for provinces that ship
/// one PDF per series (Buenos Aires) — the viewer just opens [assetPath] at
/// its first page, same as today. Both are set for provinces that ship a
/// single consolidated PDF and resolve a series to a page range instead
/// (Santa Fe).
class SeriesPdfLocation {
  const SeriesPdfLocation({
    required this.assetPath,
    this.startPage,
    this.endPage,
  });

  final String assetPath;
  final int? startPage;
  final int? endPage;
}

/// Resolves a [GisSoilSeries] read off a soil-polygon feature to where its
/// descriptive PDF material lives — the one piece of "series -> PDF"
/// plumbing that genuinely differs by province (per-series PDF file vs. one
/// consolidated PDF + page range). Everything else in `GisMapScreen`
/// (selection, measurement, markers, search) is already province-agnostic.
abstract interface class SeriesResolver {
  Future<SeriesPdfLocation?> resolve(GisSoilSeries series);
}

/// Wraps the existing [PdfSeriesRepository] mechanism (lookup by normalized
/// series *name* against `assets/pdfs/*.pdf`) without changing its
/// behavior — the default for [ProvinceConfig.buenosAires] and for any
/// `GisMapScreen` built the way it already is today (no explicit
/// `provinceConfig`/`seriesResolver`).
class BuenosAiresSeriesResolver implements SeriesResolver {
  BuenosAiresSeriesResolver(this._repository);

  final PdfSeriesRepository _repository;

  @override
  Future<SeriesPdfLocation?> resolve(GisSoilSeries series) async {
    final assetPath = await _repository.findPdfForSeries(series.name);
    if (assetPath == null) return null;
    return SeriesPdfLocation(assetPath: assetPath);
  }
}

/// Resolves a series against Santa Fe's single consolidated PDF: extracts
/// the series *code* from the raw `SERIE*` value (the same leading-token
/// rule [SantaFeSeriesRepository.dominantSeriesCode] already uses for the
/// GeoJSON `comp*` properties), normalizes it, and looks up its page range
/// in `santa_fe_series_index.json` — never by filename, since Santa Fe has
/// no per-series PDF files.
class SantaFeSeriesResolver implements SeriesResolver {
  SantaFeSeriesResolver(this._repository);

  final SantaFeSeriesRepository _repository;

  @override
  Future<SeriesPdfLocation?> resolve(GisSoilSeries series) async {
    final code = SantaFeSeriesRepository.extractSeriesCode(series.name);
    if (code == null) return null;

    final entry = await _repository.findByCode(code);
    if (entry == null) return null;

    return SeriesPdfLocation(
      assetPath: await _repository.pdfAsset,
      startPage: entry.startPage,
      endPage: entry.endPage,
    );
  }
}

/// Best-effort display name for a raw `SERIE1..6` vector-tile value — kept
/// separate from [SeriesResolver] because it solves a different problem
/// (what to *show*, synchronously, for every render) rather than where a
/// series' PDF lives (looked up once, asynchronously, on demand). Must
/// never invent a name: unresolved input is returned unchanged.
abstract interface class SeriesNameResolver {
  String resolve(String rawSeriesValue);
}

/// Buenos Aires' `SERIE1..6` values are already the real series name (e.g.
/// `"Lincoln"`) — nothing to resolve.
class IdentitySeriesNameResolver implements SeriesNameResolver {
  const IdentitySeriesNameResolver();

  @override
  String resolve(String rawSeriesValue) => rawSeriesValue;
}

/// Santa Fe's `SERIE1..6` values are raw codes with a phase suffix (e.g.
/// `"CER cc"`), not names — this resolves them against the same
/// `santa_fe_series_index.json` used for the PDF lookup, without
/// regenerating the PMTiles or duplicating the name table.
///
/// [preload] must complete before [resolve] can return a real name;
/// `GisMapScreen` calls it during its existing async archive-init sequence
/// (already gated behind a loading overlay), so this never races a visible
/// frame. Before that — or if a code has no entry in the index — [resolve]
/// falls back to the raw value, same as [SantaFeSeriesRepository.findByCode]
/// returning null: a documented degradation, not a crash.
class SantaFeSeriesNameResolver implements SeriesNameResolver {
  SantaFeSeriesNameResolver(this._repository);

  final SantaFeSeriesRepository _repository;
  Map<String, String>? _namesByNormalizedCode;

  Future<void> preload() async {
    _namesByNormalizedCode ??= await _repository.namesByNormalizedCode();
  }

  @override
  String resolve(String rawSeriesValue) {
    final names = _namesByNormalizedCode;
    if (names == null) return rawSeriesValue;

    final code = SantaFeSeriesRepository.extractSeriesCode(rawSeriesValue);
    if (code == null) return rawSeriesValue;

    return names[SantaFeSeriesRepository.normalizeCode(code)] ??
        rawSeriesValue;
  }
}
