# Sincronización de pruebas de tarjetas Córdoba

Fecha: 2026-10-26  
Repositorio: `C:\Users\jerem\suelosar`  
Rama/HEAD: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`

## Diagnóstico

Las fallas no eran errores de títulos, proporciones ni de la selección de
unidades en producción. La ficha se crea después de que
`_showFeatureAttributes` termina de enriquecer la entidad. En Córdoba esa ruta
espera la carga del índice de metadatos y, para SEl3/BYc3, también el suplemento
de porcentajes. Las pruebas anteriores usaban `rootBundle` desde el entorno de
widgets y comprobaban el título antes de que esas cargas llegaran a completar.
La evidencia previa había observado que `_showFeatureAttributes` empezaba para
Rs3, pero no alcanzaba el punto posterior al enriquecimiento.

La reproducción de Rs3 y del título fallback falló antes del cambio y pasó al
inyectar un `AssetBundle` síncrono en memoria con el contenido literal de los
dos JSON versionados del proyecto. Esto aísla la E/S del bundle de Flutter en
los tests, sin sustituir registros ni relajar aserciones. El índice conserva
sus datos y validación reales.

Había además una sincronización defectuosa en `_selectMapSearchResult`: tras
seleccionar una unidad desde la lista de series, `pumpAndSettle` esperaba que
toda la pantalla dejara de animar. El mapa puede mantener animaciones activas,
por lo que esa condición no representa la finalización de la selección. El
helper ahora espera una señal observable: la hoja con “Información general”;
para resultados de series distingue primero la lista de unidades y luego la
ficha. La espera está acotada a 40 frames de 50 ms y falla con una causa
explícita si la interfaz no llega al estado requerido. No se añadió una demora
ciega.

Rs3 y fallback se investigaron por separado: ambos fallaban individualmente al
usar el bundle predeterminado y ambos pasan con el bundle síncrono de los
activos fuente. En el grupo mínimo, E23/17 también pasó con la nueva condición
de interfaz. Por tanto, no se cambiaron lógica de producción de títulos ni
datos. Las siete fallas agrupadas se explican por la combinación de la carga
asíncrona del activo durante el test y la falta de espera por el estado final de
la ficha, no por una expectativa incorrecta o por porcentajes inválidos.

## Cambios

- `lib/gis/gis_map_screen.dart`: agrega el parámetro opcional `cardAssetBundle`
  e inicializa con él los repositorios de metadatos y porcentajes. En uso
  normal el valor es nulo y ambos repositorios siguen usando `rootBundle`.
- `test/widget_test.dart`: agrega un bundle síncrono de test alimentado desde
  `assets/data/cordoba_feature_metadata.json` y
  `assets/data/cordoba_series_percentage_supplement.json`; lo inyecta en las
  nueve regresiones de tarjeta Córdoba. El helper de selección espera los
  estados observables de selector y ficha en vez de una pausa temporal tras la
  selección.
- Este informe nuevo. No se sobrescribieron informes previos.

No se cambiaron las expectativas ni los registros verificados: SEl3 mantiene
40/20/40; BYc3 conserva 60% agregado; CoD1 conserva ocho series sin
porcentajes inventados; AEtc-2 mantiene título y composición; Bragado no cambia.

## Validación

Todos los comandos se ejecutaron en `C:\Users\jerem\suelosar`:

| Comando | Resultado |
|---|---|
| `flutter test --no-pub test/widget_test.dart --plain-name='Córdoba Rs3 card shows series and hides unavailable landscape'` | exit 0, 1/1; queda un aviso no fatal del gesto de scroll del test |
| `flutter test --no-pub test/widget_test.dart --plain-name='Córdoba title falls back to stable OBJECTID without SIMBC'` | exit 0, 1/1 |
| `flutter test --no-pub test/widget_test.dart --name='Córdoba E23/17\|Córdoba Rs3\|Córdoba title falls back'` | exit 0, 3/3 |
| `flutter test --no-pub test/widget_test.dart --name='Córdoba\|Buenos Aires Bragado'` | exit 0, 10/10 en dos ejecuciones agrupadas consecutivas |
| `flutter test --no-pub test/cordoba_series_percentage_repository_test.dart test/gis_soil_detail_metadata_test.dart test/cordoba_feature_metadata_repository_test.dart test/cordoba_series_repository_test.dart test/tool/suelosar_data/cordoba_source_metadata_test.dart test/gis_attribute_contract_test.dart` | exit 0, 43/43 |
| `flutter analyze --no-pub` | exit 1 por dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32-33`; no quedaron diagnósticos nuevos |
| `git diff --check` | exit 0; solo aviso LF→CRLF preexistente para `lib/gis/gis_soil_series.dart` |

Durante Rs3 Flutter Test emite un aviso no fatal: el centro del `Scrollable`
elegido por `scrollUntilVisible` queda fuera del viewport de prueba. La prueba
continúa y verifica las series y porcentajes. No se modificó ese gesto porque
el intento alternativo con `ensureVisible` no encontró el encabezado en ese
árbol de widgets. No afecta el resultado, pero queda como limpieza localizada
pendiente si vuelve a causar inestabilidad.

## Verificación de escritorio y límites

El proceso Windows existente sigue activo (`suelosar`, PID 35972, título de
ventana `suelosar`). La captura con Computer Use no pudo inicializarse:
`failed to write kernel assets: El sistema no puede encontrar la ruta
especificada (os error 3)`. No se afirma una nueva inspección visual. La
validación de tarjetas de esta tarea es por tests de widgets, además de los
43 tests de repositorio/modelo.

## Estado final

Rama `beta`, HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`. Se conservaron
todos los cambios rastreados, archivos no rastreados, PMTiles, `witch beta`,
`.widget_preview/` y artefactos anteriores. No se ejecutaron investigaciones
de porcentajes, benchmarks, ni operaciones de dispositivo; no se hizo commit
ni push.

**CARD TESTS VALIDATED**
