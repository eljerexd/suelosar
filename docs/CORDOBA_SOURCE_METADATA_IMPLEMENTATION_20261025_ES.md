# Correcciones de metadatos de suelo de Córdoba

Fecha: 25 de octubre de 2026

## Resultado

Se incorporó el mapeo de metadatos de clasificación y fases de serie de las fuentes de Córdoba al modelo que consume la ficha, manteniendo separados los atributos de serie y los componentes taxonómicos. Los porcentajes de subgrupos taxonómicos (`porc_1..5` en 1:500.000) no se convierten en porcentajes de series.

En la fuente 1:50.000 y 1:100.000 se mapean `clase`, `subclase`, `ip` y `fase_1..4` a `CLASE`, `SUBCLASE`, `IP` y `FASE1..4`. En 1:100.000 se conservan las ocho series ya soportadas por el normalizador. En 1:500.000 se mapean `clase` y `subclase` junto a `ip` y los campos taxonómicos existentes. El modelo asigna cada `FASEn` a su correspondiente `SERIEn`; no se crean valores si la fuente los omite.

La tarjeta presenta clase, subclase e IP con etiquetas explícitas, presenta la fase junto a la serie correspondiente y mantiene los campos taxonómicos en su sección. No se introdujo un campo `PAISAJE` ficticio para las escalas cuyo esquema no lo publica. El cambio preserva el título descriptivo de Córdoba y el comportamiento de Buenos Aires; `PORC` continúa reservado a porcentajes de series.

## Evidencia de fuente

- La fuente local `data/provinces/cordoba/source/gis/carta_suelo_100mil_2025.json`, registro `id=271` / `AEtc-2`, contiene clase `VII`, subclase `ws`, IP `10`, cuatro componentes y porcentajes `30, 30, 20, 20`; las primeras tres fases dicen «en fase moderadamente salina». La prueba aplica la configuración real del normalizador y verifica que los valores llegan a los modelos correctos.
- La fuente local `data/provinces/cordoba/source/gis/carta_suelo_500mil_2024.json`, registro `id=17` / `MNtc-2`, contiene clase `IV`, subclase `e`, IP `24`, subgrupo «Haplustol típico» y posición «Pendientes pronunciadas». `porc_1` no se interpreta como porcentaje de una serie.
- La consulta de solo lectura al WFS de IDECOR para los mismos IDs/capas confirmó los valores de AEtc-2 y MNtc-2. En la consulta del polígono AEtc-2, el agua útil del atributo (`au_2m=264`, `au_1m=151`) no coincide con los valores 222/154 del panel del visor: este último muestra capas separadas de agua útil. No se reinterpretaron ni sobrescribieron esos datos del polígono.
- La inspección interactiva del visor oficial confirmó para `CoD1` 1:100.000 las ocho series: Yacanto I, II, III, IV, Calamuchita III, San Ignacio IV, Fundación y San Pancracio. El panel no mostró proporciones para ellas.

## Validación ejecutada

- `flutter test test/gis_soil_detail_metadata_test.dart test/tool/suelosar_data/cordoba_source_metadata_test.dart test/tool/suelosar_data/schema_and_rules_test.dart` — código 0, 18 pruebas aprobadas.
- Pruebas widget enfocadas de CoD1 (series 7/8), taxonomía MNtc-2, título AEtc-2, E23/17 y referencia Buenos Aires Bragado — todas aprobadas.
- `flutter test test/gis_attribute_contract_test.dart test/tool/suelosar_data/cordoba_source_metadata_test.dart test/tool/suelosar_data/schema_and_rules_test.dart` — código 0, 16 pruebas aprobadas.
- Suite enfocada combinada Córdoba/modelo/parser/widget/contrato — código 0, 50 pruebas aprobadas.
- `flutter analyze` — código 1 únicamente por dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32,33`; no son de estos cambios.
- `git diff --check` — código 0.
- La comprobación de formato pasó para los archivos de prueba/modelo pequeños revisados. El formateador aún marca `lib/gis/gis_map_screen.dart` como distinto; no se reformateó el archivo completo porque ya contiene cambios preexistentes extensos. El hunk agregado fue revisado y ajustado manualmente para no reformatear cambios ajenos.

## Ejecución Windows y limitación

La aplicación se inició con `flutter run -d windows`; compiló y quedó ejecutándose. En el visor se abrió la ficha Córdoba `AEtc-2`. Se verificaron visualmente el título «Complejo diferenciado Arroyito y Altos de Chipión», el símbolo `AEtc-2`, el tipo/capacidad, la narrativa íntegra y las cuatro series con porcentajes 30%, 30%, 20% y 20%. La ficha no mostró las nuevas fases ni clase/subclase durante esta ejecución.

La causa es el asset publicado aún no actualizado: `data/provinces/cordoba/output/pmtiles_metadata.json` registra 31 atributos; incluye `IP` pero no `CLASE`, `SUBCLASE` ni `FASE1..4`. El PMTiles publicado conserva SHA-256 `c819fe856b84326be7d6df76cb64a10ab6c6dc62e0a9c4b3808c98540f1d1c08`. Por ello, las pruebas confirman el recorrido fuente-normalizador-modelo-widget con fixtures derivadas de registros reales, pero la presentación de los campos recién mapeados no quedó validada con el PMTiles empaquetado. No se reconstruyó el asset porque Docker Desktop/Linux Engine no estaba disponible. La prueba visual tampoco recorrió tarjetas CoD1 y MNtc-2; esas tarjetas están cubiertas por pruebas widget, no por inspección runtime.

## Estado del repositorio

Al cierre, `beta` sigue en `299248598108992fd91cd88bef31d6d1da2a8a11`. La aplicación original y el PMTiles no se modificaron. Se preservaron las modificaciones, artefactos y archivos no rastreados preexistentes, incluido `witch beta` y `.widget_preview/`. No se realizó commit ni push.

## Próximo paso

Regenerar únicamente el PMTiles de Córdoba mediante el flujo de generación aprobado cuando Docker vuelva a estar disponible; después verificar que el asset incluya `CLASE`, `SUBCLASE` y `FASE1..4` y repetir la inspección visual de AEtc-2, CoD1 y MNtc-2. Hasta entonces, las nuevas propiedades están validadas a nivel de fuente y pruebas, pero no en el mapa empaquetado.
