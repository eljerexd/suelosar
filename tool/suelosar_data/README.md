# SuelosAR Data Pipeline — Fase 1

Herramienta de línea de comandos que valida y prepara los datos de una
provincia **antes** de que lleguen a Flutter: fuentes, catálogo de cartas,
GIS normalizado, metadatos del PMTiles y un reporte. No modifica la app,
Android, Windows ni `assets/`: solo escribe en `data/provinces/<id>/`.

```text
dart run tool/suelosar_data.dart <comando> [opciones]
dart run tool/suelosar_data.dart help <comando>
```

Requisitos: el SDK de Dart/Flutter del proyecto y `pdftotext` (poppler; viene
con Git for Windows y se detecta solo) para catálogos de PDF único. El
comando `geometry` necesita Docker con la imagen `suelosar-gis-builder:local`.

## Estructura

```text
tool/suelosar_data.dart          entrada de la CLI
tool/suelosar_data/
  cli/          comandos, pipeline por etapas, plantilla de init
  config/       province.yaml y rutas
  schema/       campos destino SuelosAR (fuente única de la herramienta)
  sources/      lectores DBF, shapefile, GeoJSON, texto de PDF, GDAL (Docker)
  normalize/    mapeo declarativo campo origen -> campo SuelosAR
  catalog/      catálogos (PDF por serie / PDF único), formatos JSON, diff
  pmtiles/      metadatos del PMTiles y comparación con la app
  validation/   hallazgos, chequeos GIS y cruce GIS <-> catálogo
  report/       output/report.md y output/report.json

data/provinces/<id>/
  province.yaml   versionado
  source/         datos oficiales (ignorado por git)
  work/           normalized.geojson (ignorado)
  output/         catálogo, pmtiles_metadata.json, report.*, stages/ (ignorado)
```

## Comandos

| Comando | Qué hace | Escribe |
|---|---|---|
| `init <id>` | Crea la carpeta y un `province.yaml` plantilla. | `data/provinces/<id>/` |
| `inspect <id>` | Columnas de la fuente GIS: tipo, cobertura, valores de ejemplo. | nada |
| `validate <id>` | Todas las validaciones, sin artefactos. | `output/report.*` |
| `normalize <id>` | Aplica `gis.mapping` y mide la cobertura por campo. | `work/normalized.geojson` |
| `catalog <id> [--diff]` | Genera el catálogo; `--diff` lo compara con `catalog.reference`. | `output/<catalog.output>` |
| `metadata <archivo> \| --province <id>` | Tamaño, SHA-256, zooms, bounds, centro; compara con la app. | `--out` / `output/pmtiles_metadata.json` |
| `geometry <id>` | Geometrías nulas/inválidas antes de reparar (GDAL en Docker). | `output/stages/geometry.json` |
| `report <id>` | Rehace el reporte con las últimas etapas guardadas. | `output/report.*` |
| `build <id>` | fuentes + catálogo + GIS normalizado + cruce + PMTiles + reporte. | todo lo anterior |

Opciones globales: `--provinces-dir`, `--pdftotext`, `-v/--verbose` (muestra
los INFO). `validate`, `build`, `metadata` y `report` aceptan `--strict`
(los WARNING también fallan).

**Códigos de salida:** `0` sin errores · `1` hay hallazgos ERROR (o WARNING con
`--strict`) · `2` uso incorrecto, configuración inválida o entorno faltante.

## `province.yaml`

Ver `data/provinces/buenos_aires/province.yaml` (PDF por serie, shapefile) y
`data/provinces/santa_fe/province.yaml` (PDF único, GeoJSON). Rutas: relativas a
la carpeta de la provincia, o con `${REPO}` y variables de entorno.

Reglas de `gis.mapping` (una por campo del esquema):

| Regla | Ejemplo | Resultado |
|---|---|---|
| `from` | `TIPO: { from: tipo_ucar, empty: "" }` | copia la columna; vacío -> `empty` (por defecto `null`) |
| `from` + `{n}` | `"SERIE{n}": { from: "comp{n}", n: [1, 6] }` | `SERIE1..6` desde `comp1..6` |
| `absent` | `PAISAJE: { absent: "motivo", value: "" }` | la columna se escribe con `value`; el motivo sale en el reporte |
| `derive` | `Nombre_UC: { derive: dominant_series_name }` | nombre de la serie dominante según el catálogo |

`gis.series` define cómo se leen las series (`code_rule`: `whole_value` |
`first_token`), cómo se comparan con el catálogo (`match`: `normalized_name` como
`PdfSeriesRepository` | `case_insensitive` como `SantaFeSeriesRepository`) y
`aliases` (código GIS -> código de catálogo). `gis.thresholds` fija la cobertura
mínima de los campos principales.

`pdf.model: consolidated` genera el índice desde el sumario del PDF: cada serie
empieza en su página impresa + `page_offset` (o `auto`, que busca el título de
la primera serie y lo confirma con la última) y termina una página antes de la
siguiente entrada del sumario.

## Hallazgos

| Código | Qué detecta | Severidad |
|---|---|---|
| CFG001 | `province.yaml` inválido (sale con código 2) | — |
| CFG002 | campo del esquema no declarado en `gis.mapping` | ERROR |
| CFG003 | `derive` sin catálogo con nombres | ERROR |
| SRC001 | archivo o carpeta declarados inexistentes (PMTiles aún no generado: WARNING) | ERROR |
| SRC002 | faltan `.dbf/.shx/.prj` (ERROR) o `.cpg` (WARNING) | ERROR / WARNING |
| SRC003 | texto no decodificable (ERROR) o con doble codificación `Ã±` (WARNING) | ERROR / WARNING |
| GIS001 | columna de origen inexistente (sugiere mayúsculas) | ERROR |
| GIS002 | cobertura bajo `error_below` / `warn_below` | ERROR / WARNING |
| GIS003 | valores que son solo espacios | INFO |
| GIS004 | porcentajes no numéricos | WARNING |
| GIS005 | fuente sin features | ERROR |
| GIS006 | geometrías nulas (normalize) o inválidas (geometry) | WARNING |
| GIS007 | campo `absent` que la fuente sí tiene | WARNING |
| PDF001 | PDFs que resuelven a la misma serie | ERROR |
| PDF002 | nombres que no usan el separador declarado | WARNING |
| PDF003 | archivo `.pdf` sin cabecera PDF | ERROR |
| CAT001 | códigos/ids/PDFs repetidos | ERROR |
| CAT002 | índice desordenado o rangos de páginas inválidos | ERROR |
| CAT003 | `page_offset` no detectable o no confirmado | ERROR |
| CAT004 | nombre del catálogo actual distinto al de su archivo | WARNING |
| CAT005 | serie sin su título en la página inicial calculada | WARNING |
| CAT006 | el catálogo generado difiere del de la app | WARNING |
| CAT007 | idéntico al de la app / sin referencia | INFO |
| CAT008 | nombres de serie repetidos | WARNING |
| CAT009 | líneas del sumario no reconocidas | WARNING |
| XRF001 | series del GIS sin carta (ERROR sobre `xref.error_above_percent`, 50 % por defecto) | WARNING / ERROR |
| XRF002 | cartas sin series en el GIS | INFO |
| XRF003 | coincidencias solo por mayúsculas, alias usados | INFO |
| PMT001 | `.sha256` ausente (WARNING) o distinto (ERROR) | WARNING / ERROR |
| PMT002 | la app declara otro tamaño o bounds; archivo no usado aún (INFO) | WARNING / INFO |
| PMT003 | capa o campos del esquema ausentes en los tiles muestreados | ERROR |
| STG001 | una etapa falló inesperadamente | ERROR |

## Agregar una provincia

1. `dart run tool/suelosar_data.dart init cordoba`
2. Copiar la capa GIS a `data/provinces/cordoba/source/gis/` y los PDFs a `source/pdf/`.
3. `dart run tool/suelosar_data.dart inspect cordoba` y completar `province.yaml`.
4. `dart run tool/suelosar_data.dart build cordoba` y leer `output/report.md`.
5. Corregir datos o configuración y repetir hasta que no haya errores.
6. Generar el PMTiles con el pipeline Docker (`docker/README.md`). Hoy
   `docker/build_map.sh` solo acepta shapefiles, así que `work/normalized.geojson`
   se convierte antes con `ogr2ogr` (misma imagen) — la Fase 2 lo automatiza.
   Después, agregar `pmtiles.file` y volver a correr `build`.

## Tests

```text
flutter test test/tool/suelosar_data
$env:SUELOSAR_ACCEPTANCE = "1"; flutter test test/tool/suelosar_data/acceptance_test.dart
```
