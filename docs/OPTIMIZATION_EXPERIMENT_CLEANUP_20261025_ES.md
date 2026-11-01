# Limpieza acotada de experimentos GIS rechazados

Fecha: 2026-10-25  
Repositorio: `C:\Users\jerem\suelosar`  
Resultado: **CLEANUP PARTIAL — BLOCKED**.

## Estado inicial y protección

- Rama `beta`; HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`.
- Se conservaron los cambios locales/untracked preexistentes observados al inicio, incluido `witch beta`, `release-symbols/`, las integraciones GIS/provinciales y `docs/CORDOBA_DETAIL_CARD_AUDIT_20261025_ES.md`.
- Se verificó el manifiesto del workspace de experimentación `picture-android-ab-20261022T223053374Z`: snapshot capturado el 22-10-2026 desde esa misma rama/HEAD, con `witch beta` y datos PMTiles identificados. Su archivo baseline conserva el pre-filtro `paintBounds` y el archivo candidato de `D:\SuelosAR_Profile_20261024\paintbounds_ab_20261024\candidate` lo omite.
- No se cambió de rama, HEAD, no se hizo commit/push, ni se ejecutó limpieza de artefactos externos.

## Cambios de producción confirmados y limpieza

### `paintBounds`: revertido solo el hunk experimental

La implementación presente quitaba el getter `paintBounds` de `_RenderedGisPolygon` y, en `_buildPolygonLayer`, asignaba directamente `widget.tile.polygons`. La evidencia más fiable disponible es el snapshot `baseline/lib/gis/gis_map_screen.dart` del experimento, corroborado por el candidato aislado del 24-10 y el veredicto `PAINTBOUNDS_OPTIMIZATION_VERDICT.md` (`DO NOT INTEGRATE`). Restauré únicamente:

1. El getter `LatLngBounds? paintBounds`, derivado de `_GisBounds` y conservador para coordenadas fuera del rango geográfico.
2. El filtro previo al `PolygonLayer`: solo para tiles con polígonos Córdoba, mantiene polígonos no Córdoba, bounds nulos y bounds que solapan el viewport; descarta únicamente bounds Córdoba fuera del viewport.

Se conserva `PolygonLayer.polygonCulling: true`: el filtro propio previo y el culling interno son capas complementarias del comportamiento previo. Se conservaron las demás modificaciones del archivo GIS —entre ellas lógica de etiquetas/selección, caché, overlay provincial y estilos— porque no son el hunk de `paintBounds` rechazado y pertenecen al trabajo preexistente.

### `ui.Picture`: código de producción inspeccionado y preservado

- No se encontró en `lib/` una implementación de cache `ui.Picture` para los polígonos experimentales ni sus probes/fault hooks, contadores o flags de build.
- `rg` sí encontró uso real de `ui.PictureRecorder` en `lib/gis/offline_reference_map_layer.dart` (líneas aproximadas 210–271, 491–526 y 628), correspondiente al render/caché del mapa de referencia. Es funcionalidad existente y distinta del prototipo de caché de polígonos; se preservó.
- No se encontraron dependencias de producción agregadas para el prototipo de polígonos.
- El código de FlutterMap/probe del experimento está en workspaces/evidencia aislados, fuera del source de producción; se preservó.

### Tests y clutter

- Se conservó `test/cordoba_polygon_viewport_filter_test.dart`, que ya existía sin tracking al inicio. Su expectativa decía que todos los fragmentos se enviaran a FlutterMap, es decir, la conducta de la variante sin prefiltro. Se actualizó el test para validar el comportamiento restaurado: excluye la geometría fuera del viewport inicial, la incluye al mover el viewport y vuelve a excluirla al regresar.
- Se mantuvieron los tests generales de etiquetas y selección Córdoba; son cobertura reutilizable, no probes temporales.
- No se borraron artefactos, reportes, APKs, datos de provincias, PMTiles o archivos no trackeados.
- Flutter añadió durante los tests una sección `.widget_preview/` en `.gitignore`; se quitó únicamente esa adición generada porque `.gitignore` estaba limpio al inicio. Verificación posterior: `.gitignore` volvió a estar sin cambios.
- La ejecución de pruebas generó el scaffold `.widget_preview/` (incluye `pubspec`, `.dart_tool`, `build`, fuentes del preview y logs). El borrado recursivo de esa ruta exacta fue rechazado por la política del entorno; no se intentó eludir el bloqueo. Permanece como untracked y se debe retirar manualmente cuando el entorno permita borrar esa carpeta.

## Validación ejecutada

| Comando | Resultado |
|---|---|
| `git diff --check` | Exit 0, sin errores de whitespace (advertencia Git de conversión LF/CRLF de `.gitignore`, ya restaurado). |
| `flutter test test/cordoba_polygon_viewport_filter_test.dart test/cordoba_unit_symbol_label_test.dart` antes de actualizar la expectativa obsoleta | Exit 1; 4 pasaron y falló el test antiguo que esperaba los 5 fragmentos aun con uno fuera del viewport. |
| Mismo comando, tras actualizar esa expectativa | Exit 0; 5/5 tests. |
| `flutter test test/cordoba_series_repository_test.dart` | Exit 0; 24/24 tests. |
| `flutter test test/widget_test.dart --plain-name 'GIS map search returns the selected feature internally'` | Exit 0; 1/1. |
| `flutter test test/widget_test.dart --plain-name 'GIS rendered tile cache evicts LRU tiles and reloads them'` | Exit 0; 1/1. |
| `flutter test test/widget_test.dart --plain-name 'GIS (map search returns the selected feature internally|rendered tile cache evicts LRU tiles and reloads them)'` | Exit 1; el filtro no coincidió con ningún nombre de test. Los casos se ejecutaron individualmente y pasaron. |
| `flutter test test/widget_test.dart test/cordoba_series_repository_test.dart` | Interrumpido con Ctrl+C, exit 1, después de avanzar hasta `Home launcher opens and filters soil memories` sin más progreso por más de 30 s. No se considera una ejecución completa. La suite de Córdoba se ejecutó separadamente y pasó. |
| `flutter analyze` | Exit 1: dos infos existentes en archivo no modificado `lib/gis/multi_coverage_repository.dart:32,33`, ambos `prefer_initializing_formals`. No se alteraron para esta limpieza. |

No se ejecutó build Android ni se reconstruyeron APKs.

## Optimizaciones conservadas

- La configuración Android release mantiene `isMinifyEnabled = true`, `isShrinkResources = true`, `getDefaultProguardFile("proguard-android-optimize.txt")`, reglas Flutter y `proguard-rules.pro` en `android/app/build.gradle.kts`. No aparece modificada en Git.
- Se preservó `lib/gis/offline_reference_map_layer.dart` y su uso existente de `ui.Picture`.
- Se preservaron `PolygonLayer` y sus opciones de culling internas, los cambios no relacionados de visualización GIS, las integraciones de provincias, delivery PMTiles, búsqueda, catálogo, GPS, PDFs y el informe de auditoría de tarjetas Córdoba.
- El veredicto del experimento paintBounds continúa siendo **DO NOT INTEGRATE**: aquí solo se restableció el comportamiento previo en la rama de trabajo; los resultados prometedores y sus limitaciones quedan en sus informes externos.

## Archivos tocados por esta limpieza

- `lib/gis/gis_map_screen.dart`: reintroducido getter `paintBounds` y filtro Córdoba pre-PolygonLayer.
- `test/cordoba_polygon_viewport_filter_test.dart`: expectativa actualizada para verificar el filtro y su respuesta al movimiento del viewport.
- `docs/OPTIMIZATION_EXPERIMENT_CLEANUP_20261025_ES.md`: este informe nuevo.

No se alteró `docs/CORDOBA_DETAIL_CARD_AUDIT_20261025_ES.md` ni se implementaron correcciones de tarjetas Córdoba.

## Verificación final

- Rama/HEAD finales: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`.
- `git diff --check`: exit 0.
- `git status` muestra además `.widget_preview/`, generado por los tests de esta tarea; no se pudo retirar por el bloqueo de borrado.
- R8/DEX shrinking: presente y sin cambios.
- Se preservan las modificaciones y archivos no relacionados listados en el status inicial. El worktree **no está limpio** y no se presenta como tal.
- La validación específica del comportamiento restaurado pasa. `flutter analyze` no es verde por los dos infos mencionados; una ejecución amplia de `widget_test.dart` se estancó en un test Home y se interrumpió. El diagnóstico no demuestra que ese hang haya sido causado por estos hunks, y no se ocultó como éxito.

