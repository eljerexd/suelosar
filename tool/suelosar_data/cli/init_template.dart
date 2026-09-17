/// `province.yaml` written by `init`. Every placeholder is deliberately
/// invalid (`COMPLETAR`) so the first `validate` points at what is missing.
String provinceTemplate(String id) =>
    '''
# SuelosAR Data Pipeline — definición de la provincia "$id".
# Rutas: relativas a esta carpeta, o con \${REPO} (raíz del repo) y variables
# de entorno (\${USERPROFILE}, ...). Ver tool/suelosar_data/README.md.

id: $id
name: COMPLETAR            # nombre visible, p. ej. "Córdoba"

gis:
  source: source/gis/COMPLETAR.shp
  format: shapefile        # shapefile | geojson | geojson_lines
  # encoding: UTF-8        # shapefile: por defecto se usa el .cpg

  # Campo SuelosAR <- regla. Ver las columnas reales con:
  #   dart run tool/suelosar_data.dart inspect $id
  # Reglas: from (columna), from con {n} + n: [desde, hasta],
  #         absent (motivo obligatorio), derive (dominant_series_name).
  # "empty" es el valor cuando la columna está vacía (por defecto null).
  mapping:
    SIMBC:     { from: COMPLETAR }
    Nombre_UC: { from: COMPLETAR }
    TIPO:      { from: COMPLETAR }
    CAP_USO:   { from: COMPLETAR }
    PAISAJE:   { from: COMPLETAR }
    "SERIE{n}": { from: "COMPLETAR{n}", n: [1, 6] }
    "PORC{n}":  { from: "COMPLETAR{n}", n: [1, 6] }

  series:
    code_rule: whole_value     # whole_value (el valor es el nombre) | first_token ("CER cc" -> "CER")
    match: normalized_name     # normalized_name (PDF por serie) | case_insensitive (índice por código)
    aliases: {}                # código GIS -> código de catálogo

  thresholds:                  # cobertura mínima (%) de los campos principales
    warn_below: 90
    error_below: 50

pdf:
  model: per_series            # per_series | consolidated
  directory: source/pdf
  naming:
    word_separator: "_"        # "Villa Nueva" -> Villa_Nueva.pdf
  # Para un PDF único con todas las series:
  # model: consolidated
  # file: source/pdf/COMPLETAR.pdf
  # asset_path: assets/pdfs_$id/COMPLETAR.pdf
  # toc:
  #   pages: [1, 10]           # páginas físicas del índice
  #   series_pattern: '^\\s*Serie: (?<name>.+) \\((?<code>[^)]+)\\)\\s*\\.+\\s*(?<page>\\d+)\\s*\$'
  #   entry_pattern: '^\\s*(?<title>.+?)\\s*\\.{3,}\\s*(?<page>\\d+)\\s*\$'
  #   heading_pattern: '^\\s*Serie: {name} \\({code}\\)'
  #   page_offset: auto

catalog:
  output: soil_maps_$id.json
  json_style: standard         # standard | powershell
  # reference: \${REPO}/assets/data/COMPLETAR.json   # catálogo que ya usa la app, si existe

pmtiles:                       # generado con Docker por `build` (etapas prepare/map/optimize)
  output: ${id}_soil_polygons.pmtiles   # se publica en output/; nunca se copia a assets/
  # reference: \${REPO}/assets/maps/COMPLETAR.pmtiles   # PMTiles que ya usa la app, si existe
  layer: soil_polygons
  zooms: { min: 4, max: 14 }
  input: auto                  # auto | source | normalized
  optimize: auto               # auto | always | never
''';
