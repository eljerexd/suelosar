# Recuperación de porcentajes de series de Córdoba: seguimiento

Fecha: 2026-10-26  
Alcance: revisión de fuentes oficiales adicionales y cruce de símbolos/hojas para las posiciones que aún carecen de proporción individual. No se modificaron datos de producción ni se incorporaron porcentajes nuevos.

## Resultado

Se revisó una publicación completa adicional que no estaba archivada localmente: *Carta de Suelos de la hoja 3566-6 Villa Sarmiento*, edición 2018, que también cubre parcialmente la hoja 3566-5 Estación Modestino Pizarro. La copia local está en `data/provinces/cordoba/source/pdf/Hoja_3566-6_Villa_Sarmiento.pdf` (57 páginas; 16.505.247 bytes), descargada del [portal oficial de suelos de Córdoba](https://suelos.cba.gov.ar/VILLASARMIENTO/assets/Hoja_3566-6_Villa_Sarmiento.pdf). SHA-256: `279a85c88be04f826fb959a2c09550c7d3ab864bf2e9e124300e0358e5505cf0`.

La publicación contiene seis mapas y descripciones de unidades. En la sección 3.3.17, página impresa 35, documenta la composición de **EYr7**: El Yararí 50%, La Beatriz 30% y Huinca Renancó 20%. Se contrastó la identidad con el registro local Córdoba 1:50.000 (símbolo EYr7, `id=1233`). El WFS local ya contiene esos tres porcentajes, por lo que esta evidencia confirma los datos existentes, pero no recupera ninguna posición pendiente. No se alteró el suplemento.

El PDF y su procedencia se conservaron junto con el inventario de fuentes en `data/provinces/cordoba/source/SOURCES.md` y `data/provinces/cordoba/source/SHEET_INVENTORY.md`. No se archivaron copias temporales como reemplazo de la fuente primaria.

## Método y límites

Se usó el inventario previo para no repetir la lectura de las 59 publicaciones completas ya revisadas ni la búsqueda individual anterior. El cruce de hojas se hizo con las geometrías oficiales de `idecor:cartas_provincia_2024` y la intersección geométrica de las unidades 1:50.000/1:100.000 locales. El cruce sirve para priorizar publicaciones, no prueba por sí solo una identidad cuando una unidad toca más de una hoja. Se evitó asignar hojas por mera proximidad. Tres geometrías 1:50.000 no intersectaron ninguna geometría de hoja: Co84 (`id=1392`), CoI (`id=1153`) y ERs2 (`id=1393`); quedan sin asignación documental en este cruce.

La revisión específica de Villa Sarmiento no produjo valores nuevos. La documentación de las hojas Miramar 3163-16 y Balnearia 3163-22 continúa siendo una laguna: no se encontró una memoria oficial completa accesible para esta revisión. Los documentos de descripción individual de series 1:100.000 no se consideraron evidencia de composición de unidades; sus porcentajes de textura u otras propiedades no equivalen a proporciones de series dentro de una unidad cartográfica. Tampoco se convirtieron porcentajes de pendiente, rocosidad, salinidad u otras fases en porcentajes de composición.

El [informe de publicaciones previo](CORDOBA_PERCENTAGE_RECOVERY_PUBLICATIONS_20261026_ES.md) registra las publicaciones ya examinadas y las búsquedas anteriores, incluidas las cuatro descargas que devolvieron HTTP 403 (CoN, MNtc-9, MOtc-11 y MGtc-2). Esta revisión no repitió esa búsqueda sin una fuente nueva.

## Inventario pendiente y priorización por hoja

La base de conteo permanece sin cambios: **3.218** posiciones elegibles (2.642 a 1:50.000 y 576 a 1:100.000); 2.927 tienen porcentaje en el WFS; seis posiciones individuales tienen respaldo en el suplemento (tres SEl3 y tres Ota5). Quedan **285** sin porcentaje individual. De ellas, dos posiciones BYc3 tienen solo una proporción agregada aproximada de 60% y no admiten reparto verificable; cuatro posiciones EAr se consideran no estimables con la evidencia disponible; las otras 279 siguen siendo candidatas a investigación documental, no valores inferibles.

El cruce de las 285 posiciones produjo 95 combinaciones símbolo/escala: 65 símbolos 1:50.000 y 30 símbolos 1:100.000. La tabla resume las hojas oficiales que deben orientar futuras búsquedas; un símbolo repetido bajo varias hojas significa intersección espacial y no una identidad confirmada con una publicación concreta.

| Escala | Hoja oficial | Símbolos con posiciones pendientes que intersectan la hoja |
|---|---|---|
| 1:50.000 | 3163-13 Jesús María | BYc3, BYc5, Co22, Co25, ECj1, SPb2 |
| 1:50.000 | 3163-14 Cañada de Luque | BYc3, BYc5, BYc7, Cdl6, LCm1, SPb2 |
| 1:50.000 | 3163-20 Río Primero | BYc3, Cdl6, Ip1, LCm1, Mt2 |
| 1:50.000 | 3163-21 Santa Rosa de Río Primero | Ip1, LCñ1, RII1 |
| 1:50.000 | 3163-26 Villa del Rosario | Ip, Ip1, Mt2, RII |
| 1:50.000 | 3163-27 Arroyito | Ip, Ip1, Mt2, RII, RII1 |
| 1:50.000 | 3163-28 La Francia | EAr, Ip1, LVa1, RII1 |
| 1:50.000 | 3163-29 San Francisco | LVa1 |
| 1:50.000 | 3163-32 Oncativo | Ip, Ip1, Mt2, RII |
| 1:50.000 | 3163-33 Calchín | ELL5, Ip, Ip1, Mt2 |
| 1:50.000 | 3163-34 Las Varillas | EAr, ELL5 |
| 1:50.000 | 3363-1 Río Tercero | AsC, Co33, Co34, CoG, EAM2 |
| 1:50.000 | 3363-10 Bell Ville | EPm1, Mo, SEl, SEl1 |
| 1:50.000 | 3363-11 Leones | SEl, SEl1 |
| 1:50.000 | 3363-14 General Cabrera | Cq3 |
| 1:50.000 | 3363-15 Etruria | Cq3, GPz1, LPs4, Mo |
| 1:50.000 | 3363-20 Ucacha | LVt10, Ota6, Ota8, Rd |
| 1:50.000 | 3363-21 Pascanas | Cq3, SEf3 |
| 1:50.000 | 3363-25 Adelia María | ASt1, Ota8, VMk1 |
| 1:50.000 | 3363-26 Alejandro Roca | ECt1, ECt2, ECt4, Rd |
| 1:50.000 | 3363-27 La Carlota | LPa2, SEf3, SJo, SJo1 |
| 1:50.000 | 3363-28 Canals | Gt3, SJo, SJo1, SJo2 |
| 1:50.000 | 3363-29 Arias | ACt2, Gt, Gt2, Gt3 |
| 1:50.000 | 3363-3 James Craik | ELL5 |
| 1:50.000 | 3363-31 Vicuña Mackenna | ASt1, VMk1 |
| 1:50.000 | 3363-32 Colonia La Providencia | VRs3, VRs4 |
| 1:50.000 | 3363-33 General Viamonte | VRs3, VRs4 |
| 1:50.000 | 3363-4 Pozo del Molle | EPm1, SEl1 |
| 1:50.000 | 3363-5 Landeta | EPm1, SEl1 |
| 1:50.000 | 3363-7 Sierra de las Peñas | Co28, Co32, Co33, Co34, Co37, EAM2 |
| 1:50.000 | 3363-8 Hernando | LI1, PA |
| 1:50.000 | 3363-9 Villa María | Cq3, Mo |
| 1:50.000 | 3366-23 Estación Achiras (parcial) | CoB, CoM |
| 1:50.000 | 3366-24 Achiras | Ach3, CoB, CoC, CoM |
| 1:50.000 | 3366-29 Chaján (parcial) | Ach3 |
| 1:50.000 | 3366-30 Coronel Moldes | Ach3 |
| 1:50.000 | 3366-35 Justo Daract (parcial) | Ach3 |
| 1:50.000 | 3366-36 Washington | Ach3 |
| 1:50.000 | 3563-1 Estancia La Madrugada | VMk1 |
| 1:50.000 | 3563-13 Huinca Renancó | LRc2, LRc7, Pn3 |
| 1:50.000 | 3563-14 Buchardo | LRc2, Pn3 |
| 1:50.000 | 3563-15 Emilio V. Bunge | LRc2 |
| 1:50.000 | 3563-7 Del Campillo | LRc2, LRc7 |
| 1:50.000 | 3563-8 Jovita | LRc2, LRc7, Pn3 |
| 1:50.000 | 3563-9 Melo | LRc2 |
| 1:50.000 | 3566-12 Villa Valeria | LRc7 |
| 1:50.000 | 3566-18 Villa Huidobro | LRc7 |
| 1:100.000 | 2963-26 Villa Ojo de Agua | SPd |
| 1:100.000 | 2963-32 Villa de María | SPd |
| 1:100.000 | 3163-16 Miramar | MGtc-2, MOtc-11 |
| 1:100.000 | 3163-2 Sebastián Elcano | ERo, SPd |
| 1:100.000 | 3163-22 Balnearia | Ip1, MNtc-9, MOtc-11, RII1 |
| 1:100.000 | 3163-8 San José de la Dormida | ERo, LCm1 |
| 1:100.000 | 3166-36 Valle de Calamuchita | AsA, AsB, AsC, Co34, CoB, CoB1, CoB2, CoC, CoD, CoD1, CoG, CoH, CoH1, CoI, CoJ |
| 1:100.000 | 3366-12 Río de los Sauces | Co32, CoB, CoC, CoE, CoG, CoH, CoM, CoN |
| 1:100.000 | 3366-18 Alpa Corral | CoB, CoC, CoH, CoM, CoN, PRS |
| 1:100.000 | 3366-6 Santa Rosa de Calamuchita | AsA, AsC, Co33, Co34, CoB, CoB1, CoC, CoD, CoE, CoF, CoG, CoH, CoI |

La prioridad documental más clara es obtener una fuente completa y oficial para Miramar/Balnearia: MGtc-2 (3 posiciones), MNtc-9 (3) y MOtc-11 (4), diez posiciones en total. La publicación Villa Sarmiento recién archivada cubre hojas ya conocidas y no cambia el inventario pendiente. CoN (tres posiciones) se asocia por geometría a hojas completas ya revisadas. LRc2 aparece en varias intersecciones; su posición sobre 3563-15 Emilio V. Bunge requiere verificar identidad cartográfica antes de atribuirle una publicación.

## Verificación técnica y estado

- Pruebas repositorio/modelo: 43/43 pasaron con `flutter test --no-pub test/cordoba_series_percentage_repository_test.dart test/cordoba_series_repository_test.dart test/gis_soil_detail_metadata_test.dart test/cordoba_feature_metadata_repository_test.dart test/gis_attribute_contract_test.dart`.
- Regresiones widget, ejecutadas individualmente: SEl3, BYc3, Ota5, CoD1 (conservación de series 7 y 8), AEtc-2 y Buenos Aires Bragado: 6/6 pasaron. No se repitió el grupo completo, porque existe antecedente de fallos sensibles al orden que no forma parte de esta revisión documental.
- `flutter analyze --no-pub`: exit code 1 por dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32` y `:33`; no se observaron otros diagnósticos.
- `git diff --check`: exit code 0; Git emitió únicamente el aviso de conversión LF→CRLF para `lib/gis/gis_soil_series.dart`.
- No se ejecutaron pruebas de rendimiento, builds, dispositivo ni verificación visual en esta investigación.
- El suplemento de porcentajes y los datos de producción no se modificaron. Se añadieron únicamente la fuente primaria archivada y su registro en los inventarios locales ignorados, además de este informe.

Estado Git al cierre: rama `beta`, HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`. Se preservaron los cambios y archivos preexistentes; no se cambió de rama ni se realizaron operaciones Git mutantes. La fuente archivada está bajo `data/provinces/cordoba/source/`, excluida del seguimiento por la regla existente.

## Veredicto

**PERCENTAGE RECOVERY PARTIAL** — se archivó y revisó una nueva fuente primaria; confirmó una composición ya presente, pero no permitió recuperar porcentajes individuales adicionales. Las 285 posiciones pendientes permanecen sin cambios y sin valores inventados.
