# Optimización incremental del render GIS

- Fecha: 2026-11-03
- Rama: `beta`
HEAD de partida: `299248598108992fd91cd88bef31d6d1da2a8a11`

Este informe registra solo esta tanda incremental. La arquitectura GIS y el contrato de datos se mantienen en el código y la documentación existentes; no se reemplazó `flutter_map`, PMTiles ni la geometría oficial.

## Hallazgos medidos

El perfil Windows identificó el paneo como el cuello de botella más importante: la proyección y el culling de polígonos, las asignaciones de listas/offsets y la pintura de sus bordes. En el perfil interactivo, durante paneo sostenido, el tiempo de pintura acumulado de polígonos rondó 28,6 s en 58,7 s de pared y el p95 de frame fue 137,9 ms. PMTiles y MVT no registraron lecturas ni decodificaciones durante esa fase ya cargada. En zoom inicial sí hubo trabajo de lectura y decodificación.

La carga inicial observada mostró 24 tiles visibles, 48 de prefetch, 10 tiles decodificados, unas 9.434 geometrías visibles y 125.735 vértices. En las mediciones de widget el primer polígono apareció entre 0,56 y 1,27 s según calentamiento y contención del equipo; por esa variación no se afirma una mejora de carga inicial.

## Cambio retenido

En [gis_map_screen.dart](../lib/gis/gis_map_screen.dart), el nivel de simplificación visual de `PolygonLayer` pasa de 0,3 px en reposo a 1,5 px mientras hay un gesto de cámara. Un temporizador de inactividad de 180 ms restaura 0,3 px al detenerse. El valor se actualiza en los layers existentes; no se crea una copia simplificada de la geometría.

La simplificación solo afecta el trazado de `flutter_map`. Los objetos fuente, atributos, IDs y la ruta de hit testing (`_RenderedGisTile.hitTest`) no cambian. No se editaron datos ni se añadió almacenamiento. La prueba enfocada verifica los tres estados: 0,3 en reposo, 1,5 durante arrastre y 0,3 después de soltar.

## Comparación Profile A/B

Mismo Windows, resolución y secuencia de interacción; una repetición base y dos repeticiones de candidato, con el mismo test de integración. Se reporta `FrameTiming` en modo **Profile**, no FPS de Release. La compilación Release separada se usó para comprobar que el código de producción compila.

| Fase / métrica | Base | Candidato (media de 2) | Cambio |
|---|---:|---:|---:|
| Paneo rápido: FPS efectivo | 17,97 | 19,47 | +8,4% |
| Paneo rápido: p95 de frame | 113,05 ms | 103,78 ms | -8,2% |
| Paneo sostenido: FPS efectivo | 16,82 | 19,45 | +15,6% |
| Paneo sostenido: frame medio | 112,84 ms | 96,81 ms | -14,2% |
| Paneo sostenido: p95 de frame | 137,92 ms | 120,20 ms | -12,9% |
| Paneo sostenido: UI medio | 30,70 ms | 23,66 ms | -22,9% |
| Paneo sostenido: raster medio | 59,32 ms | 51,26 ms | -13,6% |
| Zoom-in: p95 de frame | 89,76 ms | 90,21 ms | Sin mejora concluyente |
| Cambio de heap durante paneo sostenido* | 318,3 MiB | 304,0 MiB | -4,5% |

*Es el delta de heap informado por VM Service durante la fase, no una medición de pico de memoria. No se observó crecimiento de almacenamiento: el cambio agrega solo notifier/timer y no genera assets.

Las dos corridas candidatas de paneo sostenido dieron p95 de 119,49 y 120,91 ms; las de paneo rápido, 104,11 y 103,45 ms. Todas las muestras de paneo sostenido continuaron excediendo 16,7 ms. La mejora es repetible y útil, pero no convierte el mapa en 60 FPS ni alcanza el objetivo ideal de 15–20% de reducción del p95.

## Alternativas evaluadas

- `PolygonLayer.useAltRendering`: redujo raster aproximadamente 22–27%, pero elevó trabajo UI y empeoró p95 general y de polígonos. Rechazada.
- Simplificación fija de 1 px: redujo cerca de 5,6% el p95 de polígonos en una comparación, insuficiente y degradaba detalle todo el tiempo. Rechazada.
- `useAltRendering` junto con 1 px: p95 de todos los layers apenas mejoró ~2%, pero el p95 de polígonos empeoró; rechazada.
- Separar el prefetch de los tiles visibles: primer polígono y fin del prefetch siguieron prácticamente simultáneos. No solucionó el tiempo de las 10 tiles visibles; no se integró.
- Publicar cada tile visible al terminar su decodificación: adelantó el primer polígono de 1,22–1,27 s a 0,95–0,96 s en estas corridas, pero el área completa tardó 1,30–1,33 s frente a 1,22–1,27 s, y los repaints acumulados subieron de 24 a 91–111, con pintura total de 78–153 ms frente a 78–106 ms. El costo de repaints y el riesgo de aparición fragmentada no justifican integrar esta variante sin más evidencia visual; rechazada por ahora.

El perfil posterior al LOD sigue mostrando trabajo en transformación de offsets, culling y pintura de vértices/bordes. El siguiente candidato de investigación es reducir el costo de esas transformaciones por frame sin duplicar geometría ni cambiar límites compartidos. Para carga inicial, quedan por investigar lectura PMTiles/MVT de las tiles visibles y su preparación; la prioridad de prefetch no fue el cuello de botella. No se implementó una simplificación topológica propia ni un índice espacial, porque requieren validar límites compartidos, agujeros y selección antes de alterar esa ruta.

## Validación y limitaciones

- `flutter test` sobre seis suites GIS/mapas: 14 pruebas completadas, sin fallos.
- `flutter analyze lib/gis/gis_map_screen.dart test/gis_render_performance_test.dart`: sin issues.
- `flutter build windows --release --dart-define-from-file=C:\Users\jerem\suelosar\.vscode\supabase.env.json`, desde una copia aislada: compilación correcta, 103,4 s. No se generó ni ejecutó un Setup.
- `git diff --check`: código 0; quedaron solo avisos de conversión LF/CRLF de dos archivos `generated_plugins.cmake` preexistentes.
- Suite completa: no finalizó limpia. Llegó a 373 casos y 6 skips; `Home launcher opens and filters soil memories` falló dentro de la corrida completa porque el catálogo seguía cargando y no apareció `Junín`. Ese test pasó aislado tanto en la rama actual como en la snapshot base. No se cambió el test ni se atribuye el fallo a esta modificación.
- El análisis global encontró dos infos `prefer_initializing_formals` ya existentes en `lib/gis/multi_coverage_repository.dart` y un error de import en el archivo preexistente no versionado `lib/widgets/windows_update_preview_dialog.dart` (falta `windows_update_availability_dialog.dart`). Ninguno está en los archivos modificados.
- No se capturó una grabación o screenshot del mapa durante el gesto. La fidelidad en reposo queda en el valor original 0,3 y la prueba confirma restauración; el artefacto transitorio del LOD durante el movimiento no tuvo inspección visual manual, por lo que conviene observarlo en el próximo uso de beta.
- La instrumentación de FPS disponible requiere modo Profile/VM Service. Release se compiló, pero no se presenta como benchmark de rendimiento Release.

## Archivos de esta tanda

- `lib/gis/gis_map_screen.dart`: LOD temporal durante gesto y restauración tras inactividad.
- `test/gis_render_performance_test.dart`: benchmark inicial ya existente en esta tarea y prueba enfocada del LOD.
- `docs/GIS_RENDER_OPTIMIZATION_20261103_ES.md`: este informe.

No se cambiaron geometrías, PMTiles, atributos agronómicos, versión, descargas, ramas, commits ni releases.

## Validación cruzada Release — 2026-11-04

Se hizo una segunda comprobación A/B en Release en ambas plataformas. Para recoger `FrameTiming` del renderer Release se usó un entrypoint temporal que montaba directamente el mismo `GisMapScreen` y el PMTiles incluido en assets. El entrypoint se retiró al terminar. Baseline: `GIS_ADAPTIVE_POLYGON_LOD=false`; candidato: `true`. Los APK/outputs Windows, logs y capturas quedaron fuera del repositorio en `D:\SuelosAR_GIS_Benchmark_beta_20261103`.

### Android Release

Dispositivo: AVD existente Pixel Tablet, Android 15/API 35, x86_64, viewport efectivo 320×640 a 160 dpi, perfil de recursos bajo. La configuración del AVD tiene GPU habilitada; Flutter informa Impeller/OpenGLES, siempre como emulación y no equivalente a una GPU física. No había un teléfono físico conectado. Se realizaron tres pares de corridas, cada uno con tres rondas de ocho drags ida/vuelta y una selección final; ambos builds conservaron versionCode 20. También se probaron zoom-in por doble toque y selección del polígono: la tarjeta de `La Escocia` apareció con capacidad y geometría local. Los polígonos se cargaron desde PMTiles local, sin necesitar conexión.

| Paneo Release | Baseline (mediana de 3) | Candidate (mediana de 3) | Cambio |
|---|---:|---:|---:|
| Tiempo medio por frame reportado | 84,69 ms | 77,16 ms | -8,9% |
| Throughput efectivo de la secuencia | 15,00 fps | 14,42 fps | -3,9% |
| Mediana del p95 por intervalo de 1 s | 112,05 ms | 105,42 ms | -5,9% |
| Frames sobre 16,7 ms | 100% | 100% | Sin cambio |

La mejora de latencia por frame no elevó el throughput y la secuencia siguió muy lejos de 60 fps. La variación entre las tres corridas base fue alta (52,21–85,66 ms/frame); por tanto, este AVD de software-rendering no demuestra por sí solo una mejora Release robusta ni sustituye una medición en hardware físico. En dos pares de muestras de memoria tras la misma secuencia, PSS mediano pasó de 260.868 a 254.548 KB (-2,4%) y Native Heap de 143.246 a 131.950 KB (-7,9%); son lecturas de `dumpsys meminfo` en emulador, no memoria de dispositivo real.

### Windows Release

Se compiló el renderer Windows Release con el mismo entrypoint temporal, se mostró el mapa de Buenos Aires desde PMTiles y se validó paneo, zoom z7→z10 y selección de unidad (por ejemplo `Complejo Bolivar 25`, con sus cuatro series). No se ejecutó `flutter drive --release`: Flutter rechaza expresamente ese modo para `flutter drive`; la medida se obtuvo del callback Flutter `FrameTiming` en la app Release. La captura de ventana tardó varios segundos en mostrar el canvas, por lo que las muestras de paneo son pequeñas y sensibles a la captura.

| Paneo Release: resumen de 5 drags | Baseline | Candidate | Cambio |
|---|---:|---:|---:|
| Mediana de promedio por grupo de frames | 138,80 ms | 141,51 ms | +1,9% (peor) |
| Mediana del p95 por grupo | 158,99 ms | 159,71 ms | +0,5% (prácticamente igual) |

Una única secuencia z7→z10 produjo 58,17 ms/frame de promedio y 153,47 ms de p95 en baseline (7 frames), frente a 32,50 ms y 146,74 ms en candidate (10 frames). Es una señal favorable, pero no se repitió suficientes veces para atribuir causalidad. El paneo Release no confirmó el beneficio del Profile; los grupos de 2–4 frames por acción y el retraso de la captura impiden una aceptación de rendimiento Release en Windows. Como referencia separada, los benchmarks Windows **Profile** de arriba sí mostraron mejoras repetidas de paneo y no una mejora concluyente de zoom.

### Resultado y siguientes pasos

- El cambio conserva el reposo original, restaura 0,3 px tras 180 ms sin gesto, y solo altera el trazado del `PolygonLayer`; datos fuente, selección por geometría, capacidad y propiedades de serie no cambian.
- Los tests de integración del perfil pasaron en Android; selección/deselección GIS quedó cubierta en el harness automatizado, y ambas Release mostraron selección visual con el mismo PMTiles.
- No se adopta un umbral distinto por plataforma: el Release Android de bajo recurso y el paneo Release Windows son inconclusos/mixtos; falta validar en un Android físico y con una captura Windows Release que entregue más frames sostenidos sin el costo de snapshots frecuentes.
- El candidato siguiente sigue siendo reducir costo de proyección/culling de offsets, conservando selección e IDs. No se implementó porque aún no existe una medición estable por plataforma que permita distinguirlo de carga de tiles y raster.

## Fase 2 — Transformación de coordenadas MVT y culling — 2026-11-04

Se reexaminó el trayecto de cámara a pintura. `GisMapScreen` calcula las coordenadas de tiles visibles y prefetch en cada notificación de cámara, pero retorna sin volver a cargar/publicar cuando ambos conjuntos son iguales. Para tiles nuevos incrementa un `requestId`; una respuesta obsoleta se descarta. La capa de pantalla conserva un LRU de tiles renderizados; `_RenderedGisPolygon` prepara bounds, holes, IDs y widgets, y su hit-test sigue consultando la geometría original. El repositorio ya mantiene un LRU acotado de tiles MVT (128 en esta configuración) y comparte solicitudes en curso. No se encontró decodificación repetida de tiles que permanecen en caché ni un conjunto de polígonos fuera de tiles visibles que justificara agregar un índice espacial paralelo.

### Transformación evaluada

Al decodificar una coordenada MVT, la ruta anterior recalculaba por vértice `1 << zoom`, divisiones de mundo y el origen Mercator del tile, además de la conversión inversa `exp/atan`. Se probó calcular una vez por tile los orígenes y pasos afines para longitud y Mercator-Y y conservar la fórmula de latitud. El test compara coordenadas con la implementación anterior a tolerancia `1e-10` en varios zoom/extents y verifica continuidad entre bordes de tiles.

La misma transformación afín **no se retuvo en Windows**: en Windows Release, forzarla dio 224,2 y 229,1 ms de decodificación acumulada para 10 tiles (mediana 226,6 ms), frente a 149,8 y 205,5 ms (mediana 177,7 ms) de la ruta anterior, +27,6%. El ruido de CPU impide atribuir todo el delta a la operación, pero no hay evidencia de mejora; la compilación Windows final deja activa la ruta original. No se afirma una mejora de FPS de Windows. La compilación final mostró visualmente el mapa, paneo/zoom y una selección de unidad; el callback de `FrameTiming` no entregó lotes utilizables en esta ejecución Windows.

En Android se retiene la variante afín únicamente en runtime Android, con escape de compilación `GIS_FORCE_LEGACY_MVT_PROJECTION=true` para el baseline. Tres pares Release finales, alternados sobre el AVD existente, conservaron el mismo viewport, 8 tiles visibles, 10 decodificados, 7.790 polígonos y 102.367 vértices. El total del cronómetro de `_decodeVectorTile` (aisolate MVT; no incluye lectura PMTiles) fue:

| Android Release, 3 corridas | Baseline | Candidato Android | Diferencia |
|---|---:|---:|---:|
| Decodificación MVT total, mediana | 476,6 ms | 442,7 ms | -7,1% |
| Valores por corrida | 514,1 / 472,6 / 476,6 ms | 619,5 / 442,7 / 356,2 ms | 2 de 3 candidatas mejoran |

El primer par candidato fue un outlier lento; por eso el -7,1% es una señal moderada, no una garantía de mejora individual. Un primer A/B separado de tres corridas había dado 488,5 ms vs. 436,9 ms (-10,6%); el perfil/widget de tres corridas había dado 1.265,3 ms vs. 1.115,0 ms (-11,9%). La variabilidad entre sesiones es material. El tiempo de área visible completa no mejoró de forma concluyente (una referencia previa: 1.301 vs. 1.308 ms). En el paneo Release emparejado no se encontró mejora concluyente; las medianas agregadas de frame mean fueron 86,1 ms vs. 88,6 ms y las de p95 116,7 ms vs. 119,5 ms. La secuencia final adicional de zoom/paneo/selección del candidato tuvo 93,6 ms de media y 184,2 ms p95, con 30/31 frames por encima de 16,7 ms; no es un A/B comparable y se informa como limitación, no como regresión atribuida.

Se descartó una segunda variante con memoización de latitud por fila MVT: su corrida Release en Android fue más lenta que las medianas base/candidato anteriores; además agregaba una estructura `Map` temporal por tile sin beneficio medible que justificara mantenerla. No se integra.

### Culling, cache y límites

La consulta de tiles usa un margen de un tile para prefetch; un cambio pequeño de cámara que mantiene idénticos los conjuntos visibles/prefetched no solicita geometría otra vez. No se agregó histéresis: la comparación actual de conjuntos es barata, mientras que la pintura de cientos de miles a millones de vértices siguió dominando los panes/zooms cercanos. Los escenarios cortos iniciales mostraron cero cache hits de tile; los contadores no justifican cambiar el LRU ni duplicar geometría. En las pruebas de widget se observaron hits de cache de proyección y reutilización de objetos, señal de que esas rutas existentes ya amortizan trabajo.

No se midió PSS/Native Heap para esta transformación específica. El cambio Android prepara cuatro coeficientes escalares por tile y no conserva una segunda copia de geometría; la variante de cache por filas, que sí crecía durante cada decode, se descartó. No se tocaron PMTiles, atributos, identidades, holes, multipolígonos ni selección. El test de contrato GIS, la equivalencia matemática y la selección visual (`General Guido`, símbolo `GG20`, capacidad `VIIws`) pasaron. El emulador volvió luego a la APK beta normal `1.6.0-beta`, versionCode 20, mediante instalación de reemplazo sin borrar datos; el menú normal quedó visible.

### Validación y resultado

- `flutter test` de proyección, contrato de atributos, lifecycle del repositorio, multi-coverage y render performance: 32 pruebas pasaron; también hubo una corrida intermedia de 32 pruebas para la variante por filas, que fue descartada.
- `flutter test` completo se detuvo tras 375 pruebas y 6 skips, esperando `Home launcher opens and filters soil memories` por más de un minuto; se terminó el runner propio, código 1, sin cambiar ese test. Es el mismo bloqueo de catálogo ya observado en la fase previa.
- `dart analyze` focalizado de archivos GIS cambiados: sin issues. `flutter analyze` global halló 6 diagnósticos ajenos: los dos infos `prefer_initializing_formals` en `multi_coverage_repository.dart`, tres diagnósticos del archivo suelto preexistente `lib/gis_release_benchmark_main.dart` (error de tipo `GisMapScreenState`, info `prefer_final_fields`, warning `unused_field`) y el import faltante `windows_update_availability_dialog.dart` en `lib/widgets/windows_update_preview_dialog.dart`. No se modificaron esos archivos.
- `git diff --check`: sin errores; solo las advertencias CRLF conocidas en `generated_plugins.cmake`.
- Android y Windows se compilaron en Release desde un espejo temporal fuera del repo usando el archivo de defines por ruta absoluta; su contenido no se imprimió. No hubo build de producción ni Setup.
- No se completó un benchmark físico Android. FPS del AVD no equivale a hardware real; Windows no produjo un lote de frame timings confiable en esta ejecución.
- Los APK, outputs Release Windows, logs y capturas quedaron bajo `D:\SuelosAR_GIS_Benchmark_beta_20261103\phase2-geometry-projection`. A la última medición, el árbol completo de benchmark ocupaba 63,76 GiB: `android` 3,41 GiB, `baseline` 17,72 GiB, `candidate-alt-renderer` 17,15 GiB, `windows` 2,99 GiB y `phase2-geometry-projection` 22,49 GiB. La copia parcial `source-current-beta\.claude` ocupa 0,198 GiB dentro de la última carpeta. La limpieza de copias antiguas fue solo inspeccionada: los builds de referencia/raw se preservaron; la política de ejecución bloqueó la eliminación recursiva y no se usó otra vía. Quedaban 344,75 GiB libres en D:.

**Decisión:** conservar la transformación afín **solo en Android**, por la reducción moderada de tiempo MVT en Profile y en 2/3 corridas Release finales; Windows usa sin cambios la proyección anterior. No hay evidencia de mejora global de FPS, tiempo de pantalla completa o zoom. El cuello de botella restante es el render/pintado de geometría densa; la siguiente mejora deberá atacar esa etapa solo si una medición específica demuestra una ganancia sin alterar LOD, topología o hit testing.

Archivos de esta fase: `lib/gis/gis_repository.dart`, nuevo `lib/gis/mvt_tile_projection.dart`, nuevo `test/mvt_tile_projection_test.dart` y este informe. El entrypoint temporal `lib/gis/gis_release_benchmark_main.dart` se quitó del directorio GIS al terminar; el archivo distinto `lib/gis_release_benchmark_main.dart`, que ya era untracked antes, se preservó sin cambios.
