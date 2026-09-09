class AssetPaths {
  const AssetPaths._();

  static const String soilMapsCatalog = 'assets/data/soil_maps.json';
  static const String soilMapsPdfDirectory = 'assets/pdfs';
  static const String gisPmTiles = 'assets/maps/soil_polygons.pmtiles';
  static const String gisPmTilesVersion =
      'assets/maps/soil_polygons.pmtiles.sha256';
  static const String agronomicReferenceMap =
      'assets/maps/agronomic_reference_map.json';
  static const String gisLayerName = 'soil_polygons';

  // Santa Fe — consolidated single-PDF catalog (Etapa Santa Fe Fase 1).
  // Deliberately separate from [soilMapsCatalog]/[soilMapsPdfDirectory]:
  // Buenos Aires indexes one PDF file per series by filename
  // (PdfSeriesRepository); Santa Fe ships one 640-page PDF for all 213
  // series and resolves a series to a page range instead of a file. See
  // SantaFeSeriesRepository.
  static const String santaFeSeriesIndex =
      'assets/data/santa_fe_series_index.json';

  // Santa Fe — soil-polygon PMTiles (Etapa Santa Fe Fase 3/4B). Separate
  // asset from [gisPmTiles]/[gisPmTilesVersion] so Buenos Aires' archive is
  // never touched; both share the same layer name ([gisLayerName]) since
  // the conversion pipeline reused it deliberately.
  static const String santaFeGisPmTiles =
      'assets/maps/santa_fe_soil_polygons.pmtiles';
  static const String santaFeGisPmTilesVersion =
      'assets/maps/santa_fe_soil_polygons.pmtiles.sha256';

  // Santa Fe — reference basemap (Fase 5). Same schema/style as
  // [agronomicReferenceMap] (see OfflineReferenceMapLayer) — sourced from
  // IGN WFS + GeoRef Argentina, clipped to Santa Fe's real extent.
  static const String santaFeAgronomicReferenceMap =
      'assets/maps/agronomic_reference_map_santa_fe.json';
}
