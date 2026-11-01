# Recuperación de proporciones oficiales de series de Córdoba

Fecha: 2026-10-26  
Repositorio: `C:\Users\jerem\suelosar`  
Alcance: fuentes IDECOR 1:50.000 y 1:100.000 con proporciones `PORC` ausentes; suplemento local sin cambios en los datos WFS ni en PMTiles.

## Resultado

Se recuperaron únicamente los valores que una memoria oficial atribuye expresamente a series:

- **SEl3 (1:50.000, OBJECTID 617):** Santa Elena 40%, Flora 20%, Achalay 40% (`EXACT_INDIVIDUAL`).
- **BYc3 (1:50.000, OBJECTID 1371):** Barranca Yaco y La Emilia comprenden aproximadamente 60% del complejo en conjunto (`AGGREGATE_ONLY`). La fuente no distribuye ese valor entre ambas series; no se asigna porcentaje a ninguna de ellas.
- **EAr:** la memoria dice expresamente que no fue posible estimar la participación de cada suelo (`NO_SOURCE_VALUE`).

No se encontró otra proporción individual de serie sustentada por los documentos accesibles. La recuperación es parcial, no una imputación de valores para todos los nulos.

| Clasificación | Unidades | Resultado |
|---|---:|---|
| `EXACT_INDIVIDUAL` | 1 | SEl3: tres series con valores exactos. |
| `APPROXIMATE_INDIVIDUAL` | 0 | No se encontró un valor aproximado asignado a una sola serie. |
| `AGGREGATE_ONLY` | 1 | BYc3: dos series juntas, aproximadamente 60%. |
| `NO_SOURCE_VALUE` | 79 | Memoria accesible sin proporción individual explícita; EAr declara además que no fue posible estimarla. |
| `SOURCE_UNAVAILABLE` | 4 | PDF oficial no accesible (HTTP 403); WFS también devuelve nulos. |

## Revisión de fuentes

Se enumeraron los símbolos de unidad con series y campos `PORC` ausentes en los registros Córdoba 1:50.000 y 1:100.000. Se revisaron **85 símbolos distintos**: se descargaron desde el endpoint oficial IDECOR **81 PDFs** (HTTP 200), se extrajo su texto con `pdftotext` y se cribaron las ocurrencias de `%` junto con referencias a unidades y series. Los documentos sin porcentajes explícitos de participación se clasifican como `NO_SOURCE_VALUE`; que una memoria describa series como dominantes o las ubique en sectores del paisaje no proporciona una proporción numérica.

La comprobación de los GeoJSON WFS locales confirmó **179 posiciones de serie con PORC ausente en 1:50.000** y **103 en 1:100.000**, contando solo nombres de serie en mayúsculas; los nulos de componentes descriptivos (por ejemplo, «roca expuesta» o «suelos menores») no se cuentan como series. Las fuentes publican porcentajes solo hasta `porc_5`: no hay `porc_6` para AsC 1:50.000 ni `porc_6..8` en 1:100.000 (incluidos CoH1, CoD, CoD1 y CoJ). La falta de esas columnas no se interpreta como cero ni como invitación a repartir el resto.

Los cuatro PDFs que devolvieron HTTP 403 son `CoN`, `MNtc-9`, `MOtc-11` y `MGtc-2`; se clasifican `SOURCE_UNAVAILABLE`. No se intentó eludir la restricción. Para esos cuatro símbolos, el WFS oficial 1:100.000 sí respondió y devolvió una fila por unidad, pero sus porcentajes `porc_1..porc_5` son nulos. El WFS no sustituye la memoria descriptiva inaccesible.

### Símbolos revisados

1:50.000: `ACt2`, `ASt1`, `Ach3`, `AsC`, `BYc3`, `BYc5`, `BYc7`, `Cdl6`, `Co22`, `Co25`, `Co28`, `Co32`, `Co33`, `Co34`, `Co37`, `Co84`, `CoB`, `CoC`, `CoG`, `CoI`, `CoM`, `Cq3`, `EAM2`, `EAr`, `ECj1`, `ECt1`, `ECt2`, `ECt4`, `ELL5`, `EPm1`, `ERs2`, `GPz1`, `Gt`, `Gt2`, `Gt3`, `Ip`, `Ip1`, `LCm1`, `LCñ1`, `LI1`, `LPa2`, `LPs4`, `LRc2`, `LRc7`, `LVa1`, `LVt10`, `Mo`, `Mt2`, `Ota5`, `Ota6`, `Ota8`, `PA`, `Pn3`, `RII`, `RII1`, `Rd`, `SEf3`, `SEl`, `SEl1`, `SEl3`, `SJo`, `SJo1`, `SJo2`, `SPb2`, `VMk1`, `VRs3`, `VRs4`.

1:100.000: `AsA`, `AsB`, `AsC`, `Co32`, `Co33`, `Co34`, `CoB`, `CoB1`, `CoB2`, `CoC`, `CoD`, `CoD1`, `CoE`, `CoF`, `CoG`, `CoH`, `CoH1`, `CoI`, `CoJ`, `CoM`, `CoN`, `ERo`, `Ip1`, `LCm1`, `MGtc-2`, `MNtc-9`, `MOtc-11`, `PRS`, `RII1`, `SPd`.

Un símbolo que aparece en ambas escalas se cuenta una vez en los 85 documentos por símbolo; la lista anterior conserva su presencia en cada escala.

### Pasajes que podrían confundirse con proporciones de series

- **SEl3, pág. 1:** «serie Flora 20%» y «series Santa Elena 40% y Achalay 40%». El propio texto atribuye cada proporción a su serie.
- **BYc3, pág. 1:** «Las series Barranca Yaco y La Emilia, comprenden aproximadamente un 60% del complejo». Es un total conjunto, no un reparto.
- **EAr, pág. 1:** «no ha sido posible estimar porcentajes de participación» de los suelos que componen la unidad.
- **CoD1 y CoD, pág. 1:** nombran series y dónde dominan, pero los únicos porcentajes identificados en el pasaje se refieren a roca aflorante (10–20%), no a series.
- **CoH1, Co34 y Co84:** los porcentajes cercanos a referencias de series describen pendientes o roca aflorante.
- **CoB2:** 10–25% y 25–45% describen pendiente; el bajo que representa 5% de la superficie es una posición del relieve donde aparece Calamuchita V, no una proporción explícita de esa serie.
- **AsC:** el 70% compara la Asociación A con la B en la superficie de la unidad; no cuantifica series individuales.
- **Córdoba 1:500.000:** `porc_1..5` corresponde a subgrupos taxonómicos, no a series. No se usa para rellenar `PORC`.

La proporción agregada de BYc3 tampoco se divide usando el número de series ni se descuenta de 100%. Los valores ausentes permanecen ausentes.

### Evidencia oficial conservada en el suplemento

- SEl3: [PDF oficial de unidad](https://obs-idecor-mapas-docs.obs.myhuaweicloud.com/cartas_suelos/PDF_Unidades_50mil_100mil/SEl3.pdf), pág. 1, SHA-256 `14479ec56934ce114b664927dcb021cb0c8e3e1a02539555489724f088bee21d`.
- BYc3: [PDF oficial de unidad](https://obs-idecor-mapas-docs.obs.myhuaweicloud.com/cartas_suelos/PDF_Unidades_50mil_100mil/BYc3.pdf), pág. 1, SHA-256 `f280bae5182e73fcba805e4d44f36440c08dae427d8f9c9fddeab0cb27c1ae28`.
- El [visor oficial IDECOR](https://mapascordoba.gob.ar/viewer/mapa/334) enlaza las memorias de unidad. Los cuatro enlaces con 403 no se sustituyeron por fuentes no oficiales.

Los dos PDFs se descargaron solo para verificar el texto y calcular sus hashes; las copias de revisión estuvieron en una carpeta temporal del sistema y se eliminaron al terminar el análisis. En la app solo se empaqueta el pequeño índice JSON local, sin consulta de red ni descarga de PDF al seleccionar una unidad.

SHA-256 del suplemento local: `476e875caab3ba2c382cf66043a306577baf7441a9847d95f70ee8f1fed5b08a`.

## Implementación

Se agregó `assets/data/cordoba_series_percentage_supplement.json`, con versión, escala, `OBJECTID`, `SIMBC`, clasificación, valor, URL, página, pasaje y hash de fuente. El nuevo `CordobaSeriesPercentageRepository`:

- solo considera los dos símbolos curados y confirma el par `OBJECTID`/`SIMBC` y el rango de escala del identificador;
- completa solo proporciones originales vacías y nunca cambia un `PORC` ya informado;
- conserva el orden y solo puede enriquecer series ya presentes en la feature;
- entrega la composición agregada de BYc3 en un campo separado.

La tarjeta presenta para BYc3 una nota «Composición agregada (no individual)» y aclara que la fuente no informa el porcentaje individual de cada serie. Para SEl3 los valores se muestran junto a las series correspondientes. Las demás unidades no leen el suplemento; continúan por su recorrido anterior.

Se dejaron intactos los registros WFS, el PMTiles, los porcentajes existentes de AEtc-2 (`30/30/20/20`), la ficha Bragado y las demás provincias.

## Pruebas y validación

- `flutter test --no-pub test/cordoba_series_percentage_repository_test.dart test/gis_soil_detail_metadata_test.dart test/cordoba_feature_metadata_repository_test.dart test/cordoba_series_repository_test.dart test/tool/suelosar_data/cordoba_source_metadata_test.dart test/gis_attribute_contract_test.dart` — **43 pruebas aprobadas**. Incluye SEl3, agregado aproximado BYc3, CoD1 con ocho series sin porcentajes, identidad por escala/símbolo, ausencia sin cero, prioridad de porcentajes de origen, AEtc-2 y Bragado.
- Pruebas widget ejecutadas individualmente con `flutter test --no-pub test/widget_test.dart --plain-name <nombre>` — aprobadas: SEl3, BYc3, AEtc-2, Bragado; también se ejecutaron CoD1, E23/17, Rs3, MNtc-2 1:500.000 y fallback de título en ejecuciones individuales aprobadas.
- `flutter test --no-pub test/widget_test.dart` y la ejecución agrupada de pruebas Córdoba/Buenos Aires **no quedaron verdes**: en el archivo completo se observaron siete fallos dependientes del orden, con aserciones de título que no encontraron la ficha tras `_selectMapSearchResult`; las mismas regresiones pasaron cuando se ejecutaron individualmente. No se atribuyen como fallos resueltos ni se ocultan: queda pendiente estabilizar esa suite para poder afirmar un resultado widget agregado.
- `flutter analyze --no-pub` — sin errores ni advertencias nuevas; quedan únicamente dos infos previos `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32-33`.
- `dart format` se aplicó a los dos archivos Dart nuevos/modificados pequeños. No se reformateó el archivo grande `lib/gis/gis_map_screen.dart` ni se hizo limpieza de formato ajeno en `test/widget_test.dart`.
- `git diff --check` — sin errores de whitespace.

## Archivos modificados en esta implementación

- `assets/data/cordoba_series_percentage_supplement.json` (nuevo).
- `lib/gis/cordoba_series_percentage_repository.dart` (nuevo).
- `lib/constants/asset_paths.dart` (ruta del asset).
- `pubspec.yaml` (inclusión del asset local).
- `lib/gis/gis_map_screen.dart` (enriquecimiento y nota agregada en la tarjeta).
- `test/cordoba_series_percentage_repository_test.dart` (nuevo).
- `test/widget_test.dart` (regresiones SEl3 y BYc3; conserva sus otros cambios existentes).
- `docs/CORDOBA_PERCENTAGE_RECOVERY_20261026_ES.md` (este informe).

## Estado del repositorio

- Rama verificada al inicio y al cierre: `beta`.
- HEAD: `299248598108992fd91cd88bef31d6d1da2a8a11`.
- Se preservaron las modificaciones y artefactos existentes, incluido `witch beta`, `.widget_preview/`, los PMTiles, la configuración R8/DEX, la integración Córdoba/Santa Fe y los informes anteriores. No se cambió rama ni HEAD, no hubo commit/push y no se ejecutaron experimentos de optimización.

## Veredicto

**PERCENTAGE RECOVERY PARTIAL**

Los porcentajes individuales recuperados son solo los documentados de SEl3. BYc3 conserva un porcentaje conjunto aproximado sin reparto. Para las otras 79 memorias accesibles no se obtuvo un valor individual de serie; cuatro documentos siguen inaccesibles. Esos datos no deben completarse por inferencia.
