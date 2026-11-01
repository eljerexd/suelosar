# Validación final de recuperación de porcentajes de Córdoba

Fecha: 2026-10-26  
Repositorio: `C:\Users\jerem\suelosar`

## Alcance y preservación

Se validaron el suplemento parcial de porcentajes, los modelos/repositorios relacionados y las regresiones de tarjetas. No se repitió la investigación de documentos oficiales ni se agregaron porcentajes. Se mantuvieron intactos los valores ausentes, incluidos los de CoD1, y la composición agregada de BYc3.

Estado verificado al inicio y al cierre: rama `beta`, HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`. Se conservaron las modificaciones y archivos no rastreados preexistentes. No se cambió código de producción en esta validación, no se alteraron las aserciones y se retiró toda instrumentación temporal usada para diagnosticar el orden.

## Diagnóstico del grupo de widgets

### Reproducción agrupada

Comando:

```powershell
flutter test --no-pub test/widget_test.dart --name='Córdoba|Buenos Aires Bragado'
```

Resultado: **10 pruebas seleccionadas, 3 aprobadas y 7 fallidas** (exit code 1). Pasaron E23/17, taxonomía 1:500.000 y Bragado. Fallaron:

- Rs3: no se encontró `Complejo diferenciado Rosales` (0 widgets; esperado 1).
- CoD1: no se encontró `Complejo indiferenciado Yacanto I` (0; esperado 1).
- SEl3 y BYc3: `scrollUntilVisible` no encontró el scrollable, señal de que la ficha no estaba montada.
- Fallback: no se encontró `Complejo diferenciado Serie Fallback` (0; esperado 1).
- AEtc-2 y su regresión de metadatos empaquetados: no se encontró `Complejo diferenciado Arroyito y Altos de Chipión` (0; esperado 1).

También se reprodujo el fallo con el grupo mínimo:

```powershell
flutter test --no-pub test/widget_test.dart --name='Córdoba E23/17|Córdoba Rs3'
```

E23/17 pasó y Rs3 falló al no encontrar su título.

### Ejecución individual actual

Se ejecutaron individualmente diez pruebas con `--plain-name`: E23/17, Rs3, taxonomía 1:500.000, CoD1, SEl3, BYc3, fallback, AEtc-2, metadatos empaquetados de AEtc-2 y Bragado. **8/10 pasaron**. Rs3 y fallback también fallaron individualmente en esta ejecución. Esto significa que el comportamiento observado ahora no puede describirse solamente como un problema de orden entre pruebas, aunque un reporte anterior registró que todas esas regresiones habían pasado individualmente.

### Causa observada y límite del diagnóstico

La ruta por símbolo abre la ficha directamente. La ruta por nombre de serie hace dos selecciones: primero abre el selector de unidades y luego su `ListTile` inicia la animación hacia la unidad. En producción, al terminar esa animación se llama sin espera a `_showFeatureAttributes`; para Córdoba esa función aguarda `CordobaFeatureMetadataRepository.enrichCardFeature` antes de insertar la hoja. El helper `_selectMapSearchResult` hace `pumpAndSettle` después de elegir la unidad, pero no sincroniza explícitamente la finalización de ese enriquecimiento.

La instrumentación diagnóstica temporal confirmó en la pareja mínima que `_showFeatureAttributes` comenzó para Rs3, pero no alcanzó la etapa posterior al enriquecimiento antes de la aserción. En E23/17 sí completó y abrió la ficha. El proyecto también contiene una nota en `test/ui_responsive_audit_test.dart` sobre lecturas reales de `rootBundle` que quedan en vuelo al desmontar widgets y pueden trabar lecturas posteriores. La coincidencia hace plausible una interacción con trabajo asíncrono de assets, pero **no demuestra cuál lectura queda pendiente ni por qué no completa**.

Se probaron temporalmente una espera por estado visible y la carga explícita de assets desde el helper. No estabilizaron la prueba; ambas modificaciones se retiraron. No se retuvo un cambio especulativo, no se añadieron retardos, y no se cambiaron los títulos esperados. La corrección fiable requiere aislar o sincronizar la dependencia asíncrona real de la ficha; la evidencia actual no alcanza para elegir con seguridad una modificación de producción o de infraestructura de pruebas.

## Validación de datos y controles

Comando:

```powershell
flutter test --no-pub test/cordoba_series_percentage_repository_test.dart test/gis_soil_detail_metadata_test.dart test/cordoba_feature_metadata_repository_test.dart test/cordoba_series_repository_test.dart test/tool/suelosar_data/cordoba_source_metadata_test.dart test/gis_attribute_contract_test.dart
```

Resultado: **43/43 aprobadas** (exit code 0). Se verificaron SEl3 con tres porcentajes oficiales individuales, BYc3 con proporción agregada sin reparto inventado, CoD1 con ocho series sin porcentajes fabricados, prioridad de valores de origen, identidades por escala/símbolo, ausencia de valores y compatibilidad con Buenos Aires.

`git diff --check`: **exit code 0**. Git emitió únicamente un aviso preexistente de conversión LF/CRLF para `lib/gis/gis_soil_series.dart`.

`flutter analyze --no-pub`: **exit code 1**, con solo dos infos existentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32-33`; no aparecieron errores ni diagnósticos nuevos atribuibles a esta validación.

## Windows

`flutter devices` enumeró Windows como dispositivo disponible. `flutter run -d windows` compiló y arrancó `build\windows\x64\runner\Debug\suelosar.exe`; el proceso `suelosar` quedó ejecutándose. El arranque reportó Supabase sin configurar, lo que no impidió iniciar la app.

No se verificó visualmente ninguna tarjeta en esta sesión: la herramienta de captura/control de ventanas falló dos veces al inicializar (`failed to write kernel assets: ... path not found`). Por tanto, no se afirma inspección visual actual de SEl3, BYc3, CoD1, AEtc-2 ni Bragado. La evidencia de esta ejecución para esos casos es automatizada.

## Conclusión

La recuperación de datos pasa las pruebas de repositorio/modelo, pero las regresiones widget no son estables: el grupo falla 7/10 y dos de esas regresiones fallan también individualmente en la ejecución actual. No se estableció una corrección segura ni se obtuvo verificación visual.

**PERCENTAGE RECOVERY PARTIAL — TESTS INCONCLUSIVE**
