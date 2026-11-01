# Verificación de integración de metadatos de Córdoba

Fecha: 25 de octubre de 2026  
Repositorio: `C:\Users\jerem\suelosar`  
Rama/HEAD verificados: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`

## Resultado

**INTEGRATION VERIFIED** para los metadatos de detalle descritos aquí: se generó y empaquetó el índice canónico de Córdoba, las pruebas enfocadas pasaron y la aplicación Windows compilada desde este árbol mostró las unidades verificadas. Esto no representa una aprobación de los experimentos de rendimiento ni una validación exhaustiva de todas las unidades.

## Integración y causa del faltante

Los registros fuente de Córdoba contienen clase, subclase y fases, pero el PMTiles empaquetado no conserva `CLASE`, `SUBCLASE` ni `FASE1..4`. Regenerar el gran archivo PMTiles no era necesario para el cambio aprobado. Se eligió un índice lateral pequeño derivado de los tres archivos fuente configurados para Córdoba. La generación reutiliza el lector y normalizador del pipeline existente; produce 1.423 entradas y 201.451 bytes.

La unión usa el `OBJECTID` normalizado con los offsets ya declarados en `data/provinces/cordoba/province.yaml` (50k: 0; 100k: 100.000; 500k: 500.000). El generador comprueba colisiones e identidad de símbolo cuando existe. El índice se carga de forma memoizada; la pantalla consulta solo el `OBJECTID` de la unidad seleccionada. No se escanea el conjunto completo en cada interacción ni se modifica geometría, PMTiles, selección o hit-testing.

Se incorporó `assets/data/cordoba_feature_metadata.json` a los assets Flutter. SHA-256: `0A03051A3577B8B6FDCE860BFAC280FDF846B1F5E3AC556838E370FAF5DFD496`.

El enriquecimiento rellena únicamente propiedades ausentes o vacías del feature seleccionado. Los valores existentes del PMTiles prevalecen; un identificador desconocido, una discrepancia de `SIMBC` o un fallo de carga no inventa valores ni impide mostrar la tarjeta. Las fases se asocian por número de serie y respetan la ausencia de `FASE4` para AEtc-2.

## Verificación en la aplicación Windows

La app se inició con el comando solicitado `flutter run -d windows`, compiló el runner Windows y quedó abierta. La consola informó que Supabase no está configurado porque no se proporcionaron `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY`; la sincronización queda inactiva, pero no impide consultar los datos locales. Las tarjetas siguientes fueron seleccionadas en el visor de la app y observadas visualmente en ejecución:

| Unidad | Verificación observada |
|---|---|
| Córdoba 1:100.000 `AEtc-2` | Título `Complejo diferenciado Arroyito y Altos de Chipión`; símbolo `AEtc-2`; descripción narrativa íntegra; clase VII, subclase ws, IP 10; cuatro componentes: ARROYITO 30%, ALTOS DE CHIPIÓN 30%, LA ARGENTINA 20% y suelos hidro-halomórficos 20%. Las tres primeras conservan la fase salina respaldada por fuente; el componente restante no recibe una fase inventada. |
| Córdoba 1:100.000 `CoD1` | Símbolo, descripción y taxonomía visibles. La lista completa contiene ocho series en orden, desde YACANTO I hasta SAN PANCRACIO; las series 7 y 8 son FUNDACIÓN y SAN PANCRACIO. No se muestran porcentajes porque esos valores no están disponibles en el registro fuente. |
| Córdoba 1:500.000 `MNtc-2` | Símbolo, título `Consociación MNtc-2`, paisaje `Piedemonte Sierras de Las peñas` y taxonomía visible: clase IV, subclase e, IP 24, subgrupo 1 Haplustol típico y posición 1 Pendientes pronunciadas. No se trata la proporción taxonómica como una serie. |
| Buenos Aires `Bra` | Se conserva el título `Asociacion Bragado`, símbolo Bra, paisaje `Lomas y llanos altos` y las series Bragado 70%, Norumbega 15% y Henry Bell 15%. |

La inspección visual confirma el contenido mostrado en estas cuatro tarjetas concretas. No es una revisión visual de todas las unidades ni de todas las escalas.

## Agua disponible

Los valores de agua disponible no se añadieron a las tarjetas. La comparación documentada previamente encontró diferencias entre el visor oficial y el servicio/registro local para algunas unidades (incluida CoD1). No hay evidencia suficiente para decidir cuál representación corresponde al dato desplegado; la discrepancia sigue abierta y no se ha resuelto ni normalizado.

## Pruebas y controles

| Comando/control | Resultado |
|---|---|
| `dart run tool/build_cordoba_feature_metadata.dart` | Exit 0; generó 1.423 entradas. |
| `flutter test test/cordoba_feature_metadata_repository_test.dart test/tool/suelosar_data/cordoba_feature_metadata_builder_test.dart test/tool/suelosar_data/cordoba_source_metadata_test.dart test/gis_soil_detail_metadata_test.dart test/cordoba_series_repository_test.dart` | Exit 0; 35/35 pruebas. |
| Pruebas widget enfocadas ejecutadas individualmente para título AEtc-2, metadatos empaquetados AEtc-2, series 7/8 CoD1, taxonomía MNtc-2, regresión de Buenos Aires Bragado, búsqueda Córdoba Rs3 y fallback de título por OBJECTID | Cada caso enfocado reportó éxito. Una corrida anterior agrupada de filtros widget no fue limpia y una ejecución amplia de `test/widget_test.dart` se interrumpió; no se presentan como suite completa aprobada. |
| `flutter analyze --no-pub` | Exit 1 por exactamente dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32-33`; no quedaron infos nuevas en el repositorio de metadatos. |
| `dart format --output=none --set-exit-if-changed` sobre los ocho archivos Dart implicados | Exit 0; 0 cambios pendientes de formato. |
| `git diff --check` | Exit 0; sin errores de whitespace. Git mostró solo el aviso de conversión LF/CRLF en `lib/gis/gis_soil_series.dart`. |
| `flutter devices` | Exit 0; Windows y Edge disponibles. |
| `flutter run -d windows` | Runner Windows compilado y app ejecutándose. |

No se ejecutó una suite completa de todos los tests del proyecto ni se declaró limpia la salida global del analizador; las dos infos indicadas continúan.

## Archivos de esta integración

- `tool/suelosar_data/cordoba_feature_metadata_builder.dart`
- `tool/build_cordoba_feature_metadata.dart`
- `lib/gis/cordoba_feature_metadata_repository.dart`
- `lib/constants/asset_paths.dart`
- `lib/gis/gis_map_screen.dart`
- `pubspec.yaml`
- `assets/data/cordoba_feature_metadata.json`
- `test/cordoba_feature_metadata_repository_test.dart`
- `test/tool/suelosar_data/cordoba_feature_metadata_builder_test.dart`
- `test/widget_test.dart`

Los cambios anteriores de usuario, documentos, experimentos, datos, configuraciones, `witch beta`, `.widget_preview/`, `release-symbols/` y PMTiles se preservaron. No se cambió rama ni HEAD; no hubo commit ni push.

## Estado final

Rama `beta`, HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`. La app Windows permanece abierta. La sincronización remota no está configurada en esta ejecución; los datos locales y las tarjetas inspeccionadas sí se mostraron. La discrepancia de agua disponible continúa sin resolver.
