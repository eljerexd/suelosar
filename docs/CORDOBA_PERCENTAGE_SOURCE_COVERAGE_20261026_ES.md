# Cobertura de fuentes para porcentajes pendientes de Córdoba

**Fecha:** 2026-10-26
**Alcance:** inventario y priorización de fuentes; no es una nueva campaña de extracción de porcentajes.

## Resultado

El inventario reproducible contiene **285 posiciones** sin porcentaje individual verificado. No se recuperó ningún valor nuevo y el suplemento permanece intacto. La cobertura de publicaciones queda mapeada a nivel de hoja candidata; la intersección geográfica no demuestra por sí sola que una unidad pertenezca a una edición cartográfica histórica concreta.

El detalle por posición, con registro, escala, símbolo, serie, fase, hojas candidatas, publicación, URL y hash de los PDF locales, revisión previa y motivo pendiente, está en [CORDOBA_PERCENTAGE_PENDING_POSITIONS_20261026.csv](CORDOBA_PERCENTAGE_PENDING_POSITIONS_20261026.csv).

## Reconciliación

Se consideró elegible cada ocurrencia no vacía de `serie_1..serie_8` en mayúsculas dentro de los dos GeoJSON Córdoba. No se contaron espacios vacíos ni componentes descriptivos que no son una serie.

| Cuenta | Posiciones |
|---|---:|
| Posiciones elegibles | 3.218 |
| Con `PORC` presente en el WFS local | 2.927 |
| `PORC` nulo y cubiertas por porcentaje individual exacto en el suplemento | 6 |
| Pendientes después del suplemento | **285** |

Las 285 se distribuyen en **279 proporciones individuales desconocidas**, **2 componentes agregados solamente** de BYc3 y **4 componentes documentados como no estimables** de EAr. Los dos componentes de BYc3 comparten una evidencia de composición aproximada agregada; no existe un reparto individual que pueda asignarse. EAr conserva sus cuatro posiciones como no estimables, no como oportunidades de estimación.

| Escala de datos | Posiciones pendientes |
|---|---:|
| 1:50.000 | 174 |
| 1:100.000 | 111 |
| **Total** | **285** |

El suplemento no se editó. Su SHA-256 verificado es `a090d91bc06a81d4be589023e9be3bdc4b1d70b3dd3b8a1502bc22b24d2c5c4e`.

## Cobertura cartográfica

El estado de cada fila resume las hojas de la escala correcta que intersectan su geometría. Las categorías son mutuamente excluyentes por posición; una posición puede intersectar varias hojas, por lo que los conteos hoja por hoja se solapan.

| Estado de cobertura de la posición | Cantidad | Interpretación |
|---|---:|---|
| `ARCHIVED_FULL_MAP_PDF` | 254 | Todas las hojas candidatas tienen al menos un PDF completo local en el corpus previo. El informe previo indica revisión de las publicaciones archivadas; no se conservaron pasajes negativos exactos para cada una de estas posiciones. |
| `ARCHIVED_FULL_MAP_PDF;PUBLICATION_NOT_LOCATED` | 7 | Hay tanto una hoja candidata con PDF completo como otra sin publicación localizada. No se infiere cuál edición contiene la unidad. |
| `PUBLICATION_NOT_LOCATED` | 17 | Hay hojas candidatas, pero ninguna tiene una publicación completa localizada en el catálogo local. |
| `NO_SHEET_INTERSECTION` | 7 | La geometría de la unidad no intersectó una hoja candidata de la escala correspondiente; no se asignó una publicación por proximidad. |

Así, **261** posiciones intersectan al menos un PDF completo archivado; **24** intersectan al menos una hoja cuya publicación no fue localizada (7 de ellas también intersectan una hoja archivada); y **7** no tienen hoja intersectada. Los estados por posición no se deben sumar con los conteos por hoja.

### Hojas sin publicación completa localizada

El WFS de hojas y el inventario provincial señalan las hojas siguientes. La columna de posiciones es el número de posiciones únicas dentro de esa hoja candidata, no un conteo exclusivo entre hojas.

| Hoja | Escala / edición del índice | Posiciones | Unidades y series pendientes asociadas |
|---|---|---:|---|
| 3163-16 Miramar | 1:100.000 / 2012 | 7 | MGtc-2 (3: ALTOS DE CHIPIÓN, ARROYITO, DIEGO DE ROJAS); MOtc-11 (4: DIEGO DE ROJAS, ESTANCIA DON SANTIAGO, LA PARA, POZO DE LA LOMA). |
| 3163-22 Balnearia | 1:100.000 / 2012 | 14 | MNtc-9 (3: DIEGO DE ROJAS, ESTACIÓN SANTA ROSA, ESTANCIA YOLANDA); Ip1 (3 ocurrencias: IMPIRA, IMPIRA, MATORRALES); MOtc-11 (4); RII1 (4: PILAR, RÍO SEGUNDO, SACANTA, SACANTA). |
| 3363-11 | 1:50.000; edición no asociada a memoria en el índice local | 6 | SEl1 (4) y SEl (2). |
| 3563-15 | 1:50.000; edición no asociada a memoria en el índice local | 1 | LRc2: LA RENANCÓ. |

Las dos hojas 100.000 reúnen **17 posiciones únicas**: las cuatro posiciones MOtc-11 aparecen en ambas hojas y no deben contarse dos veces. La hoja 3363-11 y la 3563-15 suman otras siete posiciones candidatas. Las posiciones SEl/SEl1 y LRc2 ya aparecen dentro del alcance del examen previo de símbolos/PDF individuales; la ausencia de publicación completa de hoja no demuestra que no exista otra fuente.

En Miramar y Balnearia hay **10 posiciones** cuyos PDF individuales IDECOR están registrados con respuesta HTTP 403: MGtc-2 (3), MNtc-9 (3) y MOtc-11 (4). Los siete restantes de esas hojas son Ip1 (3) y RII1 (4). El 403 se conserva como limitación; no se intentó eludirlo. Una publicación completa alternativa podría ser útil si se localiza en una fuente oficial.

### Unidades sin intersección de hoja

El inventario no asigna hojas por cercanía para estas siete posiciones 1:50.000:

- CoI, registro 1153: CALAMUCHITA III (1).
- Co84, registro 1392: SENDERO LUJÁN I y SENDERO LUJÁN II (2).
- ERs2, registro 1393: EL ROSARIO, ALTO GRANDE, PUESTO JACINTO y CERRO NEGRO (4).

La falta de intersección es una limitación del cruce entre las geometrías/ediciones consultadas; no prueba ausencia de documentación.

## Publicaciones ya revisadas: evitar repetición

1. Las fuentes de hojas archivadas se registran en `data/provinces/cordoba/source/SOURCES.md`; el inventario `SHEET_INVENTORY.md` vincula hoja, escala, año, página y URL disponible. El corpus previo incluye 59 revisiones de publicaciones de hoja; el seguimiento inmediatamente anterior incorporó y revisó además la memoria oficial de Villa Sarmiento. El catálogo local contiene entradas de PDFs que también incluyen material parcial, por lo que no se debe describir cada entrada como una memoria completa.
2. El informe [CORDOBA_PERCENTAGE_RECOVERY_20261026_ES.md](CORDOBA_PERCENTAGE_RECOVERY_20261026_ES.md) documenta el examen de **85 símbolos distintos** en PDFs individuales IDECOR: 81 respuestas HTTP 200 y cuatro HTTP 403 (`CoN`, `MNtc-9`, `MOtc-11`, `MGtc-2`). Sus listas por escala y los casos positivos/no estimables son la referencia para no volver a examinar los mismos PDFs sin una edición o evidencia nueva. Para la mayoría de los resultados negativos no se guardó la página/pasaje exacto por posición; el CSV lo declara expresamente.
3. Los informes [CORDOBA_PERCENTAGE_RECOVERY_PUBLICATIONS_20261026_ES.md](CORDOBA_PERCENTAGE_RECOVERY_PUBLICATIONS_20261026_ES.md) y [CORDOBA_PERCENTAGE_RECOVERY_FOLLOWUP_20261026_ES.md](CORDOBA_PERCENTAGE_RECOVERY_FOLLOWUP_20261026_ES.md) registran fuentes ya investigadas, incluidos EYr7/Villa Sarmiento y los controles SEl3, BYc3, CoD1, EAr y Ota5. No se repitió su búsqueda ni se cambió su resultado.
4. No se usaron las descripciones generales de series como evidencia de composición de una unidad. Porcentajes de pendiente, roca, erosión o salinidad no se reinterpretaron como proporciones de series.

Entre las hojas con mayor número de posiciones candidatas cubiertas por PDFs completos ya archivados aparecen Valle de Calamuchita (3166-36: 66), Santa Rosa de Calamuchita (3366-6: 43), Río de los Sauces (3366-12: 26), Alpa Corral (3366-18: 21), Jesús María (3163-13: 18) y Cañada de Luque (3163-14: 18). Estos conteos se solapan y **no** son cantidades de porcentajes recuperables. Esas fuentes están en el inventario local; releerlas no se justifica sin un pasaje, edición o documento nuevo.

## Priorización y límites

La oportunidad más clara para buscar cobertura nueva es **localizar, no asumir ni volver a descargar**, las memorias completas oficiales de Miramar (3163-16) y Balnearia (3163-22), edición 2012. Su potencial de cobertura conjunta es 17 posiciones de cinco símbolos; el catálogo local y el inventario de hojas no registran una memoria publicada ni en el portal provincial ni en el repositorio INTA. Las búsquedas oficiales focalizadas de este trabajo no localizaron una copia completa. Su contenido de composición, por tanto, es desconocido: no se las califica como prometedoras hasta comprobar que incluyen descripciones de unidades con proporciones.

Como segunda prioridad, resolver la fuente/edición de las hojas 3363-11 y 3563-15 (siete posiciones asociadas), en especial si aparece una memoria completa o una edición distinta de la ya cribada en el examen de símbolos. La siguiente verificación debe registrar URL, edición, SHA-256, páginas y pasajes por símbolo antes de actualizar la cobertura. Si no aparece una fuente oficial nueva, no hay base para otra extracción ni para inferir valores.

Limitaciones de la cobertura:

- El cruce de polígonos identifica **hojas candidatas por intersección espacial**, no una relación histórica exacta entre cada registro WFS y la edición impresa. Los datos de unidades son extracciones WFS de 2025 y no incluyen una clave de edición del relevamiento original.
- No se encontró una memoria completa oficial para Miramar ni Balnearia. El índice marca ambas como `not verified`; esto no equivale a demostrar que no existan copias fuera de los catálogos consultados.
- Para las cuatro descargas HTTP 403 no se dispone de páginas negativas del documento; no se probaron vías alternativas que eludan el acceso.
- Las 7 geometrías sin intersección requieren resolver antes su correspondencia cartográfica; asignar por proximidad sería especulativo.
- La revisión histórica de PDFs no mantuvo para cada posición una cita negativa de página. La cobertura puede evitar repetir archivos, pero no permite afirmar que cada ausencia fue demostrada exhaustivamente.

## Fuentes archivadas y reproducibilidad

El índice geométrico oficial de hojas se archivó localmente en `data/provinces/cordoba/source/gis/cartas_provincia_2024_20261026.json`, 121 registros, con origen, URL de consulta y SHA-256 registrados en `data/provinces/cordoba/source/SOURCES.md`.

- IDECOR [visor Cartas de Suelo](https://mapascordoba.gob.ar/viewer/mapa/334).
- IDECOR WFS `idecor:cartas_provincia_2024`: [endpoint oficial](https://idecor-ws.mapascordoba.gob.ar/geoserver/idecor/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=idecor%3Acartas_provincia_2024&outputFormat=application%2Fjson&srsName=EPSG%3A4326).
- Portal provincial/INTA de memorias: [suelos.cba.gov.ar](https://suelos.cba.gov.ar/).
- Repositorio Institucional INTA consultado como catálogo de memorias disponibles.

Hashes de entradas usados por el generador:

| Entrada | SHA-256 |
|---|---|
| WFS unidades 1:50.000 | `280e3de24dbcfe7e3fbb1fcb74318b73e2a5c42a47f33e4c7a9e72b1902a2c13` |
| WFS unidades 1:100.000 | `a338767d901a42dbd16ddbda8eea365e1bcaf63ebca6220230791fe7395ecc0b` |
| Suplemento (sin cambios) | `a090d91bc06a81d4be589023e9be3bdc4b1d70b3dd3b8a1502bc22b24d2c5c4e` |
| Geometría WFS hojas archivada | `fdda41db80f46de65734f3fedf36ff98f9db26e38057f1f714b42fe7a5cd4ceb` |
| `SHEET_INVENTORY.md` | `7303215e1321e8e399bf81c2b339c3b40ccf2d6e4a6f9fc6699a8bbdced1ac1d` |
| `SOURCES.md` | `c77dd4c3a7ab54421011101de4dde85c9ce0624b0552e91f796c5f946403e8fe` |
| Informe base de revisión de símbolos | `e4d1783b284374b7535b3fdb4e3f75801cdb8a98848d0bb5ceffbd360e9b59ba` |

El generador sin dependencias externas es `tool/suelosar_data/cordoba_percentage_pending_inventory.mjs`. Se ejecutó dos veces contra los mismos insumos: ambas produjeron 285 filas y el mismo SHA-256 de CSV, `3e11a31b4346ff9abdc2dfd1568c2e1b7578536eb5f71cc4856555295da4d4f1`. El resumen reproducido fue 3.218 elegibles, 291 nulos originales, 6 exactos en suplemento y 285 pendientes.

## Validación y estado

- `node --check tool/suelosar_data/cordoba_percentage_pending_inventory.mjs`: **exit 0**.
- Generación determinista, dos ejecuciones: **285 filas; hashes idénticos**.
- `git diff --check`: **exit 0**. Git emitió una advertencia de conversión LF/CRLF para un archivo de trabajo preexistente (`lib/gis/gis_soil_series.dart`); no se formateó ni cambió ese archivo en esta tarea.
- Tests/modelo/widget/análisis Flutter: no ejecutados, porque no cambió suplemento ni código de aplicación.
- No se recuperaron porcentajes nuevos; suplemento, PMTiles, producción y tests de la app no se modificaron.
- Rama `beta`; HEAD esperado y observado: `299248598108992fd91cd88bef31d6d1da2a8a11`. El árbol ya tenía cambios y archivos no rastreados antes de esta tarea; se conservaron. Los nuevos artefactos de cobertura son este informe, el CSV y el generador.

## Veredicto

**SOURCE COVERAGE MAPPED**
