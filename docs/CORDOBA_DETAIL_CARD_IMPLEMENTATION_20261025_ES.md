# Implementación de fichas de detalle Córdoba

Fecha: 2026-10-25  
Repositorio: `C:\Users\jerem\suelosar`  
Rama / HEAD verificados: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`

## Correcciones

- **Título:** la ficha compartida usa para Córdoba `SIMBC` como identidad breve publicada (`Unidad cartográfica E23/17`, `Rs3`, `MNtc-2` o `CoD1`). No toma el `Nombre_UC` narrativo como encabezado. Si falta el símbolo, usa `OBJECTID` y luego el ID estable del feature. La descripción narrativa original queda en “Descripción de la unidad”; no se recortan porcentajes con heurísticas.
- **Series:** `GisSoilSeries.fromProperties` conserva `SERIE1..SERIE8` en orden fuente. Omite huecos y no crea filas vacías. Los porcentajes se muestran solo cuando el `PORCn` correspondiente existe; para `SERIE7/8` sin proporción se presenta “Sin porcentaje”.
- **Taxonomía:** se añadió un modelo separado para `IP`, `SUBGRUPO1..5` y `POSICION1..5`, y la tarjeta lo muestra en “Clasificación taxonómica” solamente si hay valores. No se reutiliza `PORC` (porcentaje de serie) para porcentajes taxonómicos.
- **Paisaje:** la sección solo aparece cuando `PAISAJE` contiene un valor fuente no vacío. Así, Córdoba 1:50k/1:100k no muestra “Sin datos” como si fuera una descripción; Córdoba 1:500k y Bragado conservan sus valores disponibles.
- **Buenos Aires:** sigue usando `Nombre_UC` como título y conserva paisaje y series.
- **Error de análisis:** `test/widget_test.dart` construía un `GisArchiveInfo` parametrizado con `const`, causando `Invalid constant value`. Se quitó `const`; el fixture sigue usando coordenadas específicas por provincia.

Referencias principales: [gis_map_screen.dart](../lib/gis/gis_map_screen.dart#L5713), [gis_soil_series.dart](../lib/gis/gis_soil_series.dart#L22), [gis_soil_taxonomy.dart](../lib/gis/gis_soil_taxonomy.dart#L2), [province.yaml Córdoba](../data/provinces/cordoba/province.yaml#L48), y pruebas en [widget_test.dart](../test/widget_test.dart#L2407) y [gis_soil_detail_metadata_test.dart](../test/gis_soil_detail_metadata_test.dart).

## Pruebas

Se ejecutaron individualmente con `flutter test test/widget_test.dart --plain-name '<nombre>'`; cada comando terminó con exit 0:

- `Córdoba E23/17 uses its symbol title and retains source details`
- `Córdoba Rs3 card shows series and hides unavailable landscape`
- `Córdoba 1:500,000 displays available taxonomy fields`
- `Córdoba 1:100,000 detail card retains series 7 and 8`
- `Córdoba title falls back to stable OBJECTID without SIMBC`
- `Buenos Aires Bragado card keeps its name, landscape and series`

También pasaron con exit 0:

- `flutter test test/gis_soil_detail_metadata_test.dart` — 4 tests.
- `flutter test test/cordoba_series_repository_test.dart` — 24 tests.
- `flutter test test/cordoba_unit_symbol_label_test.dart` — 4 tests.
- `flutter test test/cordoba_polygon_viewport_filter_test.dart` — 1 test.
- Cinco pruebas existentes de `widget_test.dart` para búsqueda, selección, favoritos, bottom sheet y centrado — cada ejecución con `--plain-name` terminó en exit 0.
- `git diff --check` — exit 0.
- `dart format` en los modelos y tests cambiados — exit 0, 0 archivos modificados por el formateador.

`flutter analyze` terminó en **exit 1** con dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32,33`. Ya no informa `Invalid constant value`; no se limpió esa deuda ajena. El formato global de `gis_map_screen.dart` aún detecta diferencias preexistentes; no se reformateó el archivo grande entero.

## Ejecución Windows

- `flutter devices` — exit 0; detectó `Windows (desktop)` y `Edge`.
- `flutter run -d windows` — compiló `build\windows\x64\runner\Debug\suelosar.exe` correctamente y abrió la app en modo debug. `flutter run` permanece activo, por lo que no tiene código de salida final. El log mostró Supabase sin configurar (sin credenciales), pero la app inició y llegó al mapa GIS.
- **Inspección visual:** se verificó la ventana de SuelosAR y que abre el mapa. No se logró abrir las fichas Bragado y Córdoba: el control de búsqueda aparecía y reportaba foco, pero `type_text`/tecla no cambiaron su valor y la acción de accesibilidad por índice devolvió que el elemento no estaba disponible en la caché de la ventana. Por tanto no se afirma inspección visual runtime de ninguna ficha. Las fichas sí quedaron comprobadas por las seis pruebas widget anteriores.

## Archivos de esta implementación

- `lib/gis/gis_map_screen.dart`
- `lib/gis/gis_soil_series.dart`
- `lib/gis/gis_soil_taxonomy.dart` (nuevo)
- `test/widget_test.dart`
- `test/gis_soil_detail_metadata_test.dart` (nuevo)
- Este informe.

El prefilter `paintBounds`, la configuración R8, PMTiles, informes previos y cambios no relacionados no se revirtieron ni limpiaron. Se preservó `witch beta` (SHA-256 `021723B591A635C9CF7D3030310CC4120E6565A6A3CA2A8CCA23F293A568B22`), `.widget_preview/`, `release-symbols/` y todos los demás artefactos del estado inicial. No se cambió rama, HEAD, ni se hizo commit o push.

## Límites restantes

La fuente Córdoba 1:50k/1:100k no publica `PAISAJE`; no se inventa un reemplazo. `PORC7/8` no existe en el esquema consultado, de modo que las series 7/8 aparecen sin porcentaje. La taxonomía se conserva separada de series y solo se presenta donde sus propiedades están disponibles. Aunque las pruebas widget validan contenido y comportamiento, queda pendiente la inspección visual manual de ambas fichas en la app Windows.
