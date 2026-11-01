# Corrección del título de AEtc-2

## Resultado

La tarjeta Córdoba para `AEtc-2` ahora muestra **Complejo diferenciado Arroyito y Altos de Chipión**. Mantiene `AEtc-2` en `Símbolo`, conserva completa la descripción original y deja las cuatro entradas y sus proporciones en `Series de suelo`.

## Evidencia y criterio

La tarjeta del registro real fue inspeccionada en la aplicación Windows después de iniciar la versión actualizada. La información mostrada confirma:

- Tipo: `Complejo diferenciado`.
- Símbolo: `AEtc-2`.
- Series: `ARROYITO 30%`, `ALTOS DE CHIPIÓN 30%`, `LA ARGENTINA 20%` y `suelos hidro-halomórficos 20%`.
- Descripción preservada: `Complejo en fase moderadamente salina de Series PERFIL N°15 30%; PERFIL N°16 30%; PERFIL N°9 20% y otros suelos hidro-halomórficos`.

Los nombres de serie se obtienen de los campos `SERIE1..SERIE8` y las proporciones de `PORC1..PORC8` mediante `GisSoilSeries.fromProperties` (`lib/gis/gis_soil_series.dart:19-33`). En este registro, `PERFIL N°15/16/9` está en el texto narrativo y no sustituye los nombres formales presentados por la sección de series. El índice cordobés también contiene los nombres `ARROYITO`, `ALTOS DE CHIPIÓN` y `LA ARGENTINA` (`assets/data/cordoba_series_index.json:103,128,953`).

Para el título se toma el tipo de unidad y todas las series formales con la mayor proporción; si hay empate, se muestran juntas siguiendo el orden de origen. En `AEtc-2`, Arroyito y Altos de Chipión comparten el máximo de 30%, por eso el título incluye ambas. Los componentes en minúsculas que describen suelos asociados permanecen íntegros en la composición de series, pero no se presentan como nombres formales en el título. Si no hay porcentajes utilizables, se usa la primera serie formal disponible; si no hay nombres de serie, se conserva una identificación estable de la unidad.

La rama Buenos Aires sigue usando `Nombre_UC`, por lo que el título `Asociacion Bragado` y su comportamiento no cambian.

## Cambio y pruebas

- `lib/gis/gis_map_screen.dart:5972-6037`: título Córdoba derivado de tipo y serie(s) dominantes; el símbolo y la descripción continúan en sus secciones propias. La ruta de título de Buenos Aires no cambia.
- `test/widget_test.dart:2662-2749`: regresión de `AEtc-2` que comprueba título, símbolo, narrativa, las cuatro series y porcentajes; regresión Bragado conserva título, paisaje y series.
- Las regresiones Córdoba existentes cubren `E23/17`, `Rs3`, taxonomía 1:500.000, series 7/8 y fallback por `OBJECTID` (`test/widget_test.dart:2406-2660`).

Resultados ejecutados:

| Comprobación | Resultado |
|---|---|
| Test enfocado `Córdoba AEtc-2 title uses both co-dominant source series` | Pasó, 1/1 |
| Regresiones enfocadas Córdoba y Buenos Aires (ejecutadas individualmente) | Pasaron |
| `flutter test test/gis_soil_detail_metadata_test.dart` | Pasó, 4 pruebas |
| `flutter test test/cordoba_series_repository_test.dart` | Pasó, 24 pruebas |
| `flutter analyze` | Exit 1 por dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32-33`; no se informaron nuevos diagnósticos de esta corrección |
| `dart format --output=none --set-exit-if-changed test/widget_test.dart` | Pasó, sin cambios pendientes de formato en ese archivo |
| `git diff --check` | Exit 0; Git mostró un aviso CRLF/LF para el archivo preexistente `lib/gis/gis_soil_series.dart` |
| `flutter run -d windows` | Compiló correctamente; se observó el título actualizado en la tarjeta real |

La comprobación de formato del archivo completo `lib/gis/gis_map_screen.dart` sigue detectando formato pendiente en ese archivo grande; no se reformateó para evitar cambios ajenos al ajuste.

## Estado visual y del repositorio

La captura runtime posterior al reinicio muestra el título `Complejo diferenciado Arroyito y Altos de Chipión`; también muestra `AEtc-2` como símbolo y la descripción original sin truncar en su sección. El árbol de accesibilidad confirma la lista completa de series y porcentajes. La tarjeta Bragado ya se había verificado en runtime antes de este cambio y su regresión enfocada continúa pasando.

Estado final verificado: rama `beta`, HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`. Se preservaron los cambios y archivos no relacionados existentes. No se realizó commit ni push.
