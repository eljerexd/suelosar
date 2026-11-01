# Recuperación de porcentajes de series desde memorias completas

Fecha: 2026-10-26  
Repositorio: `C:\Users\jerem\suelosar`  
Rama/HEAD comprobados: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`

## Resultado

Se incorporaron **tres porcentajes individuales nuevos**, todos para la unidad
Ota5 de Córdoba 1:50.000. La memoria de la hoja PASCANAS publica expresamente
40%, 30% y 30%; el orden, los nombres y la fase coinciden con el registro WFS
local `OBJECTID=1281`, `SIMBC=Ota5`. No se repartieron proporciones agregadas
ni se asignaron cifras de otras unidades o escalas.

Con los tres valores anteriores de SEl3, el suplemento contiene ahora seis
posiciones de serie con valores individuales exactos. BYc3 conserva su dato
agregado aproximado de 60% para Barranca Yaco y La Emilia, sin reparto
individual. El resultado general sigue siendo parcial.

## Evidencia Ota5

- Fuente cartográfica: `data/provinces/cordoba/source/gis/carta_suelo_50mil_2025.json`.
- Registro: `id=1281` (OBJECTID local), `SIMBC=Ota5`, escala 1:50.000.
- SHA-256 del GeoJSON 1:50.000: `280e3de24dbcfe7e3fbb1fcb74318b73e2a5c42a47f33e4c7a9e72b1902a2c13`, coincidente con `data/provinces/cordoba/source/SOURCES.md`.
- Fuente primaria: hoja 3363-21, PASCANAS, edición 1993; PDF oficial [Hoja 3363-21 PASCANAS](https://suelos.cba.gov.ar/PASCANAS/assets/Hoja_3363-21_Pascanas.pdf), sección 3.3.38, página PDF e impresa 61.
- SHA-256 de la copia local verificada `data/provinces/cordoba/source/pdf/Hoja_3363-21_Pascanas.pdf`: `450697da69d5fff1522023e86d9829d26dd2ea7d4aa4278cfaf0ef6f7aca72a0`, idéntico al inventario local de fuentes.
- El encabezado describe OLAETA 40%; LA VICTORIA 30%; OLAETA moderadamente alcalina en profundidad 30%.
- El registro WFS tiene, en ese orden, `OLAETA` sin fase, `LA VICTORIA` sin fase y `OLAETA` con fase `en fase moderadamente alcalina en profundidad`. Los valores suman 100%.
- SHA-256 del suplemento resultante `assets/data/cordoba_series_percentage_supplement.json`: `a090d91bc06a81d4be589023e9be3bdc4b1d70b3dd3b8a1502bc22b24d2c5c4e`.

El suplemento y el repositorio emparejan cada valor por `OBJECTID`, símbolo,
escala, nombre de serie **y fase**. Esto evita asignar el 40% y el 30% a ambas
filas que se llaman OLAETA. La fuente se limita a la unidad Ota5; no se modificó
el GeoJSON ni PMTiles.

La documentación de IDECOR establece que las delineaciones identificadas con
el mismo símbolo constituyen una unidad cartográfica; esa convención respalda
el uso del símbolo junto con la composición y la escala para cotejar la unidad,
pero no sustituye el cotejo de fase y de la lista de componentes: [IDECOR,
actualización del mapa continuo de Cartas de Suelo](https://www.idecor.gob.ar/nuevo-mapa-continuo-de-cartas-de-suelo-remejorado/).

## Búsqueda y descartes

Se partió de las 85 combinaciones símbolo/escala con posiciones `PORC` ausentes
del informe previo. Se revisaron las ocurrencias localizadas en las memorias
completas disponibles en el archivo local: 59 PDFs de hojas de Córdoba y el PDF
general local; se excluyó el PDF de series de Santa Fe. La búsqueda de páginas
fue una selección de candidatos, no una afirmación de que todo el catálogo
provincial de memorias esté archivado localmente. El inventario enumera hojas
adicionales con PDF remoto, memorias HTML y hojas sin memoria localizada.

Los porcentajes en títulos no bastaron por sí solos. Se contrastaron unidad,
escala, orden, nombre y fase con los campos WFS actuales:

- **Ota5, PASCANAS:** los tres componentes coinciden exactamente; se incorporó
  40/30/30.
- **Ip1, VILLA DEL ROSARIO, 1:50.000:** el encabezado publica IMPIRA 50%,
  IMPIRA en fase sódica superficial 40% y 10% de suelos menores. El registro
  WFS actual incluye además MATORRALES en fase moderadamente sódica profunda y
  una fila distinta de suelos en capas arenosas salinas/alcalinas. No hay
  correspondencia suficiente para asignar los tres valores a todos los
  componentes actuales; no se incorporó ningún porcentaje.
- **LPs4, CALCHÍN, 1:50.000:** la publicación describe LA PLAYOSA 30%,
  SACANTA en fase salina 30%, IMPIRA 20% y suelos fluviales 20%. El WFS actual
  para LPs4 contiene LA PLAYOSA, AUSONIA, GENERAL PAZ y suelos menores
  alcalinos; la lista no coincide. No se incorporó ningún porcentaje.
- **BYc3:** la memoria confirma aproximadamente 60% conjunto para Barranca
  Yaco y La Emilia; no proporciona un reparto individual. Se conserva como
  `AGGREGATE_ONLY`.
- **EAr:** la memoria declara que no fue posible estimar la participación de
  cada suelo; se conserva como sin valor individual.
- Otros números próximos a símbolos describen pendientes, roca expuesta,
  inclusiones, distribución del paisaje u otra unidad (por ejemplo, Gt4 no es
  uno de los registros objetivo Gt/Gt2/Gt3). No se interpretaron como
  proporciones de las series objetivo.

No se usaron los campos porcentuales de Córdoba 1:500.000 para series: allí
corresponden a subgrupos taxonómicos. Tampoco se inventaron valores donde la
fuente no los da.

Como comprobación adicional acotada, se consultó en modo lectura la memoria
HTML oficial de NOROESTE (`https://suelos.cba.gov.ar/NOROESTE/index.html`),
inventariada como fuente HTML sin PDF. Se buscaron los símbolos objetivo
1:100.000 como identificadores completos dentro del texto visible extraído de
la página; las coincidencias iniciales por subcadena resultaron ser partes de
palabras narrativas, no códigos de unidad. No se encontró en esa página una
tabla o referencia que vincule uno de esos símbolos con un porcentaje de
series. Por tanto, esta consulta no aporta valores adicionales ni sustituye
la revisión de las memorias completas de las hojas que el inventario enumera
como enlaces remotos o no localizadas. No se descargaron archivos adicionales.

## Recuento actualizado

El recuento se calculó sobre los GeoJSON locales actuales contando posiciones
no vacías `serie_1..serie_8` cuyo nombre está en mayúsculas y cuyo `porc_n` es
nulo/vacío. Se excluyeron componentes descriptivos en minúscula; son
**ocurrencias de componentes**, no nombres únicos.

| Escala | Posiciones de series | Sin porcentaje en WFS | Nuevas/existentes exactas en suplemento | Aún sin porcentaje individual | Registros con algún faltante (antes → ahora) |
|---|---:|---:|---:|---:|---:|
| 1:50.000 | 2.642 | 180 | 6 (SEl3: 3; Ota5: 3) | 174 | 67 → 65 |
| 1:100.000 | 576 | 111 | 0 | 111 | 30 → 30 |
| **Total** | **3.218** | **291** | **6** | **285** | **97 → 95** |

El informe previo registró 179 posiciones faltantes a 1:50.000 y 103 a
1:100.000 (282 total). El GeoJSON 1:50.000 actual tiene el mismo hash que el
inventario, pero la diferencia de una posición respecto de ese informe no
quedó explicada por sus registros. Para el GeoJSON 1:100.000 el inventario no
conserva un hash histórico comparable; el archivo local actual tiene SHA-256
`a338767d901a42dbd16ddbda8eea365e1bcaf63ebca6220230791fe7395ecc0b`. Por ello,
los 111 actuales describen el archivo local presente, no una reconciliación
retroactiva de la cifra histórica. No se alteraron los archivos fuente.

El inventario de fuentes conserva además cuatro PDFs individuales IDECOR que
el informe previo no pudo descargar (CoN, MNtc-9, MOtc-11 y MGtc-2). La
existencia de un símbolo homónimo en otra escala o en otra hoja no se tomó
como evidencia suficiente para trasladar porcentajes a esos registros.

## Cambios y validación

Archivos tocados por esta recuperación:

- `assets/data/cordoba_series_percentage_supplement.json`: registro Ota5 y
  fase de cada porcentaje; se conservan intactos SEl3 y el agregado BYc3.
- `lib/gis/cordoba_series_percentage_repository.dart`: coincidencia por
  nombre+fase para manejar series repetidas sin cruzar valores.
- `test/cordoba_series_percentage_repository_test.dart`: recuperación Ota5
  40/30/30, suma, no-mutación de PORC fuente y rechazo de fase no coincidente.
- `test/widget_test.dart`: verificación de la tarjeta Ota5 y sus dos filas
  OLAETA; se mantienen los tests SEl3 y BYc3.
- Este informe.

Resultados ejecutados:

- `dart format lib/gis/cordoba_series_percentage_repository.dart test/cordoba_series_percentage_repository_test.dart` — sin cambios pendientes. El test widget Ota5 quedó formateado; se conservó sin reformat una aserción preexistente ajena en `test/widget_test.dart` para evitar churn no relacionado.
- `flutter test --no-pub test/cordoba_series_percentage_repository_test.dart` — 8/8 aprobadas.
- `flutter test --no-pub test/widget_test.dart --plain-name 'Córdoba Ota5 card displays the three official proportions'` — 1/1 aprobada.
- Prueba individual del widget SEl3 — 1/1 aprobada.
- Prueba individual del widget BYc3 — 1/1 aprobada.
- Conjunto de repositorio/modelo/atributos y metadatos Córdoba — 45/45 aprobadas.
- `flutter analyze --no-pub` — sin errores ni advertencias; quedan únicamente los dos infos previos `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32-33`.
- `git diff --check` — exit 0; informó un aviso preexistente de conversión LF/CRLF en `lib/gis/gis_soil_series.dart`, que no se modificó en esta tarea.

No se lanzó la aplicación Windows ni se hizo verificación visual; la verificación
de Ota5 fue automatizada. No se ejecutaron benchmarks ni se descargaron PDFs
adicionales; la consulta HTML indicada arriba fue solo lectura. No se
modificaron PMTiles o geometrías.

## Estado final

Se preservaron la rama `beta`, HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`
y los cambios/untracked preexistentes. La reconciliación exacta con los conteos
del informe anterior sigue limitada por la falta de hash histórico del GeoJSON
1:100.000 y por la diferencia de una posición en el 1:50.000.

**PERCENTAGE RECOVERY PARTIAL**
