# SuelosAR Data Pipeline — Fase 2

Herramienta de línea de comandos que valida y prepara los datos de una
provincia **antes** de que lleguen a Flutter: fuentes, catálogo de cartas,
GIS normalizado, PMTiles generado con Docker, optimizado y verificado,
metadatos y un reporte. No modifica la app,
Android, Windows ni `assets/`: solo escribe en `data/provinces/<id>/`.

```text
dart run tool/suelosar_data.dart <comando> [opciones]
dart run tool/suelosar_data.dart help <comando>
```

Requisitos: el SDK de Dart/Flutter del proyecto y `pdftotext` (poppler; viene
con Git for Windows y se detecta solo) para catálogos de PDF único. El
comando `geometry` y la etapa `map` de `build` necesitan Docker Desktop; la
imagen `suelosar-gis-builder:local` se reconstruye sola cuando cambian los
scripts de `docker/` (se marca con la etiqueta `suelosar.scripts`).

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
  gis_build/    entrada del mapa (prepare-gis) y `docker run` (map)
  pmtiles/      optimizador genérico, chequeos, metadatos, comparación con la app
  validation/   hallazgos, chequeos GIS y cruce GIS <-> catálogo
  report/       output/report.md y output/report.json

data/provinces/<id>/
  province.yaml   versionado
  source/         datos oficiales (ignorado por git)
  work/           normalized.geojson, map_input/, pmtiles/, stamps/, logs/ (ignorado)
  output/         catálogo, <pmtiles.output> + .sha256, pmtiles_metadata.json,
                  report.*, stages/ (ignorado)
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
| `prepare-gis <id>` | Decide la entrada del mapa (fuente original o normalizado) y la prepara. | `work/map_input/` |
| `map <id> [--dry-run]` | `docker run` de `build_map.sh`; `--dry-run` solo muestra el comando. | `work/pmtiles/<stem>.full.pmtiles`, `work/logs/map.log` |
| `optimize <id>` | Quita atributos fuera del esquema y verifica cada tile. | `work/pmtiles/<output>` |
| `optimize --input A --output B [--mode]` | Lo mismo para cualquier archivo, sin provincia. | `B`, `B.sha256` |
| `build <id> [--force] [--from E] [--until E]` | catálogo, normalize, prepare, map, optimize, metadata (publicación), cruce y reporte; reanudable. | todo lo anterior + `output/<pmtiles.output>` |

Opciones globales: `--provinces-dir`, `--pdftotext`, `-v/--verbose` (muestra
los INFO). `validate`, `build`, `metadata` y `report` aceptan `--strict`
(los WARNING también fallan).

**Códigos de salida:** `0` sin errores · `1` hay hallazgos ERROR (o WARNING con
`--strict`) · `2` uso incorrecto, configuración inválida o entorno faltante.

## `province.yaml`

Ver `data/provinces/buenos_aires/province.yaml` (PDF por serie, shapefile) y
`data/provinces/santa_fe/province.yaml` (PDF único, GeoJSON). Rutas: relativas a
la carpeta de la provincia, o con `${REPO}` y variables de entorno.

`gis.format`:

| Formato | Archivo | Lectura |
|---|---|---|
| `shapefile` | `.shp` + `.dbf`/`.shx`/`.prj` (`.cpg`) | DBF por registro |
| `geojson_lines` | FeatureCollection con un feature por línea (GDAL, Santa Fe) | por línea |
| `geojson` | FeatureCollection con cualquier disposición: indentado o todo en una línea (exportaciones WFS) | escaneo en flujo: solo el feature en curso queda en memoria |

En los dos formatos GeoJSON (UTF-8) se decodifican solo las `properties`; la
`geometry` se conserva como el texto original. Un archivo de una sola línea
declarado como `geojson_lines` se rechaza indicando usar `geojson`.

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
`aliases` (código GIS -> código de catálogo). `not_series` (opcional) es una
expresión regular: los valores de `SERIEn` que la cumplen son componentes que no
son series ("suelos menores", "roca expuesta"); quedan en los datos pero no se
buscan en el catálogo (XRF004). `gis.thresholds` fija la cobertura mínima de los
campos principales.

`pdf.model: consolidated` genera el índice desde el sumario del PDF: cada serie
empieza en su página impresa + `page_offset` (o `auto`, que busca el título de
la primera serie y lo confirma con la última) y termina una página antes de la
siguiente entrada del sumario.

`pmtiles`:

| Clave | Por defecto | Qué hace |
|---|---|---|
| `output` | `<id>_soil_polygons.pmtiles` | nombre del archivo publicado en `output/` (sin carpetas) |
| `reference` | — | PMTiles que ya usa la app, solo para comparar (antes `file`) |
| `layer` | `soil_polygons` | capa vectorial |
| `zooms` | `{ min: 4, max: 14 }` | `min` 0–6, `max` 13–20 |
| `input` | `auto` | `source`: la fuente original (requiere mapeo directo); `normalized`: `work/normalized.geojson`, con textos vacíos como null; `auto`: `source` si el mapeo es directo y la fuente es shapefile |
| `optimize` | `auto` | `auto`: reescribe solo si hay atributos fuera del esquema, si no copia; `always`; `never` |

## Reanudación y publicación

Cada etapa de `build` guarda una huella en `work/stamps/<etapa>.json`: hashes de
sus entradas y de su configuración (y, para `map`, de los scripts Docker y la
imagen) más los hashes de sus salidas. Si nada cambió y la corrida anterior no
tuvo errores, la etapa se **reutiliza** (↺ en el reporte, con lo que había
tardado). `--force` vuelve a correr todo; `--from E` fuerza desde `E`;
`--until E` corta después de `E`. `prepare-gis` y `map` equivalen a
`build --from X --until X`.

El PMTiles se copia a `output/<pmtiles.output>` (con `.sha256` y
`pmtiles_metadata.json`) solo si `normalize`, `prepare`, `map`, `optimize` y los
chequeos del archivo terminaron sin ERROR; si no, se borra lo publicado antes.
Nada se copia a `assets/`: el reporte lista los **pasos manuales pendientes**.

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
| XRF004 | valores de `SERIEn` excluidos por `gis.series.not_series` | INFO |
| PMT001 | `.sha256` ausente (WARNING) o distinto (ERROR) | WARNING / ERROR |
| PMT002 | la app declara otro tamaño o bounds; archivo no usado aún (INFO) | WARNING / INFO |
| PMT003 | capa o campos del esquema ausentes en los tiles muestreados | ERROR |
| PMT004 | el PMTiles generado difiere del de la app (WARNING); idéntico o sin referencia (INFO) | WARNING / INFO |
| DKR000 | Docker no disponible (en `validate`) | WARNING |
| DKR001 | Docker no disponible (`build`/`map`; sale con código 2) | — |
| DKR002 | `build_map.sh` falló (ver `work/logs/map.log`) | ERROR |
| PRE000 | ruta elegida para la entrada del mapa y valores vaciados | INFO |
| PRE001 | `pmtiles.input: source` con un mapeo que no es directo | ERROR |
| MAP001 | el archivo generado no coincide con la configuración (versión, tipo, zooms, capa, hash) | ERROR |
| MAP002 | zooms sin tiles | ERROR |
| MAP003 | bounds fuera de la extensión de la fuente | WARNING |
| OPT001 | falta un campo requerido del esquema: no se publica | ERROR |
| OPT002 | estructura de PMTiles no soportada por el optimizador | ERROR |
| OPT003 | resumen de la optimización | INFO |
| PUB001 | PMTiles no publicado, con el motivo | INFO |
| PUB002 | la copia publicada no coincide con el hash | ERROR |
| STG001 | una etapa falló inesperadamente | ERROR |
| STG002 | etapa omitida porque falló o falta una anterior | INFO |

## Agregar una provincia

1. `dart run tool/suelosar_data.dart init cordoba`
2. Copiar la capa GIS a `data/provinces/cordoba/source/gis/` y los PDFs a `source/pdf/`.
3. `dart run tool/suelosar_data.dart inspect cordoba` y completar `province.yaml`.
4. `dart run tool/suelosar_data.dart build cordoba` y leer `output/report.md`.
5. Corregir datos o configuración y repetir hasta que no haya errores.
6. `build` genera el PMTiles con Docker y lo publica en `output/`. Revisar
   `PASOS MANUALES PENDIENTES` en el reporte: copiar a `assets/`, registrar la
   provincia en la app, actualizar tamaño y bounds.

## Tests

```text
flutter test test/tool/suelosar_data
$env:SUELOSAR_ACCEPTANCE = "1"; flutter test test/tool/suelosar_data/acceptance_test.dart
$env:SUELOSAR_DOCKER = "1"; flutter test test/tool/suelosar_data/docker_build_test.dart
```
