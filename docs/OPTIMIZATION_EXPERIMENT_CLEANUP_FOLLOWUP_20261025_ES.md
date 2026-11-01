# Limpieza de experimentos GIS: verificación final

Fecha: 2026-10-25  
Repositorio: `C:\Users\jerem\suelosar`  
Resultado: **CLEANUP COMPLETE — no se encontraron cambios rechazados que deban retirarse del código de producción.**

## Protección y estado inicial

- Rama verificada: `beta`.
- HEAD: `299248598108992fd91cd88bef31d6d1da2a8a11`.
- Se preservaron todas las modificaciones y entradas sin seguimiento existentes; no se cambiaron ramas ni se usaron operaciones destructivas de Git.
- `witch beta` sigue presente con SHA-256 `021723B591A635C9CF7D3030310CC4120E6565A6A3CA2A8CCA23F293A568B22`.
- `.widget_preview/`, `release-symbols/`, PMTiles, informes, pruebas y demás trabajo local permanecen intactos.

## Hallazgos de código

### `ui.Picture` de polígonos

La búsqueda del código activo no encontró `VectorCacheProbe`, `VectorFaultProbe`, `vectorPictures` ni `vectorPictureTile` en `lib/` o `test/`. El experimento de caché `ui.Picture` para polígonos no está integrado en la app.

`lib/gis/offline_reference_map_layer.dart` sí usa `ui.PictureRecorder` y `Canvas.drawPicture` para capas de referencia y etiquetas. Ese archivo no está modificado en el árbol de trabajo y esa funcionalidad no es el caché experimental de polígonos; se conservó.

### Prefiltro `paintBounds`

El código actual en `lib/gis/gis_map_screen.dart` contiene el comportamiento previo al experimento:

- `hasCordobaPolygons` y `paintBounds` calculan los límites geográficos.
- `_GisTilePolygonLayerState._buildPolygonLayer` prepara `paintPolygons` y excluye fragmentos de Córdoba fuera de `visibleBounds`, con fallback para límites no válidos.
- La clave de caché comprueba la identidad de tile y la lista filtrada.

Ese comportamiento está presente en el snapshot baseline conservado en `C:\Users\jerem\suelosar-supervisor\optimization-workspaces\picture-android-ab-20261022T223053374Z\baseline\lib\gis\gis_map_screen.dart`, SHA-256 `656464E451F205679F8DB8979279AAAA4A2E1729A104527A8F4C5CBEAFFCF305`. La copia candidata de `D:\SuelosAR_Profile_20261024\paintbounds_ab_20261024\candidate\lib\gis\gis_map_screen.dart` usa `final paintPolygons = widget.tile.polygons`, es decir, omite el prefiltrado. El veredicto archivado `PAINTBOUNDS_OPTIMIZATION_VERDICT.md` confirma que esa diferencia permaneció aislada y que no se aplicó al beta original. Por eso no se revirtió el filtro.

El hash actual completo de `lib/gis/gis_map_screen.dart` es `11FC14220B6436280F89D770EEEFEB4D30E17C3ED7A88E525F017CAF4FC49F3B`, distinto del snapshot por otros cambios locales legítimos. La comparación y decisión se limitaron al hunk del prefiltrado; no se restauró el archivo completo ni se tocaron los cambios de fichas, etiquetas, selección u otras integraciones.

No se identificaron flags, imports ni dependencias de producción exclusivos del candidato rechazado que deban eliminarse. La prueba sin seguimiento `test/cordoba_polygon_viewport_filter_test.dart` cubre el comportamiento que permanece activo y se conservó.

## Optimizaciones conservadas

La configuración Android de reducción R8/recursos continúa habilitada: `android/app/build.gradle.kts` conserva `isMinifyEnabled = true`, `isShrinkResources = true` y las reglas ProGuard. `git diff --exit-code -- android/app/build.gradle.kts android/app/proguard-rules.pro` terminó con código 0. No se modificaron manifiestos, módulos deferred ni entrega PMTiles.

No se borraron informes, APKs, manifests ni workspaces experimentales externos. Esta tarea solo limpió/verificó el código de producción; no hizo limpieza del almacenamiento experimental.

## Validación

- `flutter test test/gis_soil_detail_metadata_test.dart`: exit 0, 4 pruebas.
- `flutter test test/cordoba_series_repository_test.dart`: exit 0, 24 pruebas.
- `flutter test test/cordoba_unit_symbol_label_test.dart`: exit 0, 4 pruebas.
- `flutter test test/cordoba_polygon_viewport_filter_test.dart`: exit 0, 1 prueba.
- `git diff --check`: exit 0.
- `dart format --output=none --set-exit-if-changed` sobre `gis_soil_series.dart`, `gis_soil_taxonomy.dart` y pruebas de metadatos/widgets: exit 0, sin archivos reformateados.
- `flutter analyze`: exit 1. Reportó dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32,33` y un error de compilación en la prueba de ficha que ya estaba en el árbol al iniciar esta limpieza: `test/widget_test.dart:3135`, `Invalid constant value` (coordenadas configurables dentro de un `const GisArchiveInfo`). No se corrigió porque es trabajo de la ficha Córdoba, expresamente fuera del alcance de esta limpieza.
- La verificación de formato del archivo grande `lib/gis/gis_map_screen.dart` indica que el archivo completo no está formateado por `dart format`; no se ejecutó un formateo global para evitar alterar hunks locales ajenos.

Las pruebas widget puntuales de las fichas se habían intentado durante el trabajo anterior. No se cuentan como validación final de esta limpieza: al restaurar el estado de ficha que existía al inicio de la limpieza, el fixture conserva el error `const` señalado por el análisis. No se ejecutó `flutter run` ni se lanzó la app.

## Estado final

El HEAD y la rama no cambiaron. Permanecen los cambios locales preexistentes, las fichas Córdoba pendientes, las integraciones de provincias, `witch beta`, PMTiles, `.widget_preview/`, `release-symbols/` y toda la evidencia. No se eliminó ni revirtió ningún archivo. El cierre significa que los experimentos rechazados especificados no dejaron código de polígonos que retirar; no significa que el árbol de trabajo esté limpio ni que el análisis completo sea verde.
