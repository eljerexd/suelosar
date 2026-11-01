# Seguimiento de fichas de suelo de Córdoba

Fecha: 25 de octubre de 2026  
Repositorio: `C:\Users\jerem\suelosar`  
Rama: `beta`  
HEAD: `299248598108992fd91cd88bef31d6d1da2a8a11`

## Resultado

La ruta de series del árbol de trabajo conserva los índices 1 a 8 y la ficha itera la lista completa; no se encontró un límite de seis en ese recorrido. Se reforzaron las pruebas con los registros fuente reales de Córdoba. El registro 86 (`CoD1`) contiene ocho series ordenadas: YACANTO I, YACANTO II, YACANTO III, YACANTO IV, CALAMUCHITA III, SAN IGNACIO IV, FUNDACIÓN y SAN PANCRACIO. No contiene proporciones: `porc_1..5` son nulos y no hay `porc_6..8`. Por tanto, las pruebas verifican que no se inventen porcentajes y que todas las series se muestren.

El registro 17 de 1:500.000 (`MNtc-2`) conserva índice de productividad `24`, subgrupo `Haplustol típico` y posición `Pendientes pronunciadas`. La tarjeta existente presenta la sección rotulada **Taxonomía** y esos valores. No se deriva taxonomía para escalas cuyos datos no la proveen.

La corrección de título `AEtc-2` y su prueba existente permanecen intactas. También se mantiene la regresión de Buenos Aires para `Asociacion Bragado`, paisaje y serie.

## Archivos modificados en esta continuación

- `test/gis_soil_detail_metadata_test.dart`: fixtures y aserciones del parser basados en CoD1 y MNtc-2 reales; orden de ocho series, proporciones opcionales ausentes y taxonomía ausente.
- `test/widget_test.dart`: fixture del caso 1:100.000 reemplazado por los datos reales de CoD1 y comprobación de las ocho series y ausencia de porcentajes ficticios. Las pruebas previas de AEtc-2, MNtc-2 y Bragado se conservaron.

No se necesitó modificar lógica de producción en esta continuación: el recorrido de ocho series y la presentación condicional de taxonomía ya estaban implementados en el árbol de trabajo. No se modificó el registro ni la configuración de paisajes.

## Verificación

Comandos ejecutados desde la raíz del proyecto:

- `flutter test test/gis_soil_detail_metadata_test.dart` — aprobado, 4 pruebas.
- `flutter test test/widget_test.dart --plain-name "Córdoba 1:100,000 detail card retains series 7 and 8"` — aprobado.
- `flutter test test/widget_test.dart --plain-name "Córdoba 1:500,000 displays available taxonomy fields"` — aprobado.
- `flutter test test/widget_test.dart --plain-name "Córdoba E23/17 titles the unit from its dominant soil series"` — aprobado.
- `flutter test test/widget_test.dart --plain-name "Córdoba AEtc-2 title uses both co-dominant source series"` — aprobado.
- `flutter test test/widget_test.dart --plain-name "Buenos Aires Bragado card keeps its name, landscape and series"` — aprobado.
- `dart format --output=none --set-exit-if-changed test/gis_soil_detail_metadata_test.dart test/widget_test.dart` — código 0, sin archivos pendientes de formato.
- `git diff --check` — código 0. Git mostró únicamente una advertencia de conversión LF/CRLF ya asociada a `lib/gis/gis_soil_series.dart`.
- `flutter analyze` — código 1 por dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32` y `:33`; no son hallazgos de estas pruebas/tarjetas.

## Ejecución Windows

Se ejecutó `flutter run -d windows`; la compilación finalizó y la app quedó abierta. La ficha CoD1 se abrió en runtime. Se observaron el título `Complejo indiferenciado Yacanto I`, símbolo `CoD1`, la descripción completa, las ocho series en orden y la etiqueta `Sin porcentaje` cuando la fuente no da proporciones. También se abrió visualmente la ficha MNtc-2: aparecen la sección `Clasificación taxonómica`, el paisaje y el símbolo/tipo esperados; el árbol accesible confirmó `IP 24`, `Haplustol típico` y `Pendientes pronunciadas`. Bragado no se inspeccionó visualmente en esta ejecución; su regresión widget sí pasó.

## Estado preservado y limitaciones

La rama y HEAD se verificaron al finalizar: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`. El árbol de trabajo ya contenía cambios y artefactos ajenos a esta continuación; no se limpiaron ni descartaron. El analizador sigue sin quedar limpio por los dos infos mencionados. No se inventaron proporciones para CoD1 ni campos de paisaje o taxonomía ausentes.
