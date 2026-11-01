# Continuación de recuperación de porcentajes de series de Córdoba

Fecha: 2026-10-28  
Repositorio: `C:\Users\jerem\suelosar`  
Rama/HEAD: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`

## Alcance y preservación

Se retomó la investigación directamente en la copia principal de `beta`, no en el worktree de rendimiento. Antes de inspeccionar se comprobó la ruta exacta, rama, HEAD, estado staged/unstaged y archivos no rastreados. El árbol ya contenía modificaciones locales en código, pruebas, configuración y datos, además de `witch beta`, `.widget_preview/`, mapas PMTiles, suplementos y reportes. Todo ese estado se preservó. No se cambió la rama ni el HEAD y no se modificaron GeoJSON, PMTiles, suplementos, código o pruebas durante esta continuación.

Se consultaron los informes de recuperación, maximización, cobertura y publicaciones; el inventario `SHEET_INVENTORY.md`, el catálogo local `SOURCES.md`, el CSV de posiciones pendientes y los GeoJSON actuales. Las búsquedas web se limitaron a fuentes oficiales del portal de suelos de Córdoba, IDECOR y el Repositorio Institucional INTA, con foco en las hojas completas que los inventarios previos señalan como no localizadas. No se volvió a descargar ni reprocesar el corpus previo de PDFs individuales.

## Recuento actual reproducido

Se contó cada ocurrencia no vacía de `serie_1..serie_8` en mayúsculas en los GeoJSON 1:50.000 y 1:100.000; se consideró con porcentaje cualquier `porc_n` no nulo/no vacío, y luego se cotejaron las posiciones restantes con entradas `EXACT_INDIVIDUAL` del suplemento por registro, serie y fase.

| Escala | Posiciones elegibles | `PORC` en el GeoJSON | Nulas en origen | Exactas en suplemento | Aún sin porcentaje individual |
|---|---:|---:|---:|---:|---:|
| 1:50.000 | 2.642 | 2.462 | 180 | 6 | 174 |
| 1:100.000 | 576 | 465 | 111 | 0 | 111 |
| **Total** | **3.218** | **2.927** | **291** | **6** | **285** |

Las seis posiciones exactas del suplemento son tres de SEl3 y tres de Ota5. Las 285 restantes se mantienen clasificadas como 279 de proporción individual desconocida, dos posiciones de BYc3 cubiertas únicamente por una proporción agregada aproximada cercana al 60% (sin reparto entre componentes) y cuatro posiciones EAr que la fuente disponible documenta como no estimables. No se descontó ni distribuyó ningún agregado.

Hashes SHA-256 de los insumos comprobados:

- `data/provinces/cordoba/source/gis/carta_suelo_50mil_2025.json`: `280e3de24dbcfe7e3fbb1fcb74318b73e2a5c42a47f33e4c7a9e72b1902a2c13`.
- `data/provinces/cordoba/source/gis/carta_suelo_100mil_2025.json`: `a338767d901a42dbd16ddbda8eea365e1bcaf63ebca6220230791fe7395ecc0b`.
- `assets/data/cordoba_series_percentage_supplement.json`: `a090d91bc06a81d4be589023e9be3bdc4b1d70b3dd3b8a1502bc22b24d2c5c4e`.
- `docs/CORDOBA_PERCENTAGE_PENDING_POSITIONS_20261026.csv`: `3e11a31b4346ff9abdc2dfd1568c2e1b7578536eb5f71cc4856555295da4d4f1`.

Los conteos reproducen el informe de cobertura del 26 de octubre. La diferencia histórica de una posición 1:50.000 respecto del primer informe sigue explicada por el recálculo posterior del GeoJSON y no se reinterpretó aquí.

## Revisión documental nueva

El inventario actual identifica como lagunas principales las memorias completas de Miramar (hoja 3163-16, escala 1:100.000) y Balnearia (3163-22, 1:100.000), además de Leones (3363-11, 1:50.000) y Emilio V. Bunge (3563-15, 1:50.000). Se revisaron de nuevo, de forma focalizada, búsquedas por las hojas/nombres exactos en el portal provincial y el Repositorio Institucional INTA. No se localizó una copia primaria completa, nueva y accesible que permita verificar composiciones de unidad para incorporar porcentajes.

El resultado negativo de un buscador no prueba que la publicación no exista. Para Miramar/Balnearia, el inventario local del WFS registra edición 2012 pero no URL ni PDF completo; hay referencias bibliográficas secundarias que mencionan 2013, lo cual no autentica qué edición corresponde a los registros ni revela su contenido. Se mantiene la identidad/edición como pendiente de resolver con portada y colofón de una copia primaria. No se usó esa referencia secundaria para asignar datos.

La cobertura existente deja además siete posiciones sin intersección con una hoja de la escala correspondiente: CoI (registro 1153, una serie), Co84 (1392, dos) y ERs2 (1393, cuatro). No se les asignó una hoja por proximidad. Las posiciones asociadas a hojas sin publicación completa localizada siguen siendo candidatas para búsqueda documental, no proporciones deducibles. Los cuatro PDF unitarios previamente inaccesibles (CoN, MNtc-9, MOtc-11 y MGtc-2) no se intentaron eludir ni se descargaron nuevamente.

## Resultado de esta continuación

No se encontró una fuente primaria nueva con un porcentaje individual verificable y, por lo tanto, no se agregó ningún valor al suplemento. Los porcentajes existentes de SEl3 y Ota5, el agregado de BYc3, los faltantes de EAr, el orden y las fases permanecen intactos. No se cambió la política de preservar nulos cuando la fuente no los estima.

Fuentes institucionales de consulta y procedencia existente:

- [Visor de Cartas de Suelo de IDECOR](https://mapascordoba.gob.ar/viewer/mapa/334).
- [Portal provincial de Cartas de Suelo](https://suelos.cba.gov.ar/).
- [Repositorio Institucional INTA](https://repositorio.inta.gob.ar/).
- Catálogo local de hojas y ediciones: `data/provinces/cordoba/source/SHEET_INVENTORY.md`.
- Registro local de PDFs y hashes: `data/provinces/cordoba/source/SOURCES.md`.
- Inventario reproducible de posiciones: `docs/CORDOBA_PERCENTAGE_PENDING_POSITIONS_20261026.csv`.
- Reconciliación y cobertura previa: `docs/CORDOBA_PERCENTAGE_SOURCE_COVERAGE_20261026_ES.md` y `docs/CORDOBA_PERCENTAGE_RECOVERY_MAXIMIZATION_20261026_ES.md`.

No se archivaron nuevos PDFs porque no se encontró ni descargó una publicación primaria pertinente. Cuando aparezca una copia oficial, deberá preservarse primero en el archivo local de fuentes con URL, edición, tamaño y SHA-256, y recién entonces cotejarse cada unidad, escala, componente y fase.

## Validación ejecutada

- `flutter test --no-pub test/cordoba_series_percentage_repository_test.dart test/cordoba_series_repository_test.dart test/gis_soil_detail_metadata_test.dart test/cordoba_feature_metadata_repository_test.dart test/gis_attribute_contract_test.dart` — exit code 0; 43 pruebas pasaron.
- Pruebas widget ejecutadas individualmente con `flutter test --no-pub test/widget_test.dart --plain-name <nombre>` — exit code 0 en cada caso: SEl3, Ota5, BYc3, AEtc-2 y Buenos Aires Bragado. Se mantuvo el patrón individual porque el historial registra fallos sensibles al orden al agrupar parte de esta suite; este resultado no certifica que todo `widget_test.dart` pase agrupado.
- `flutter analyze --no-pub` — exit code 1 por dos infos existentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32` y `:33`; no aparecieron diagnósticos nuevos.
- `dart format --output=none --set-exit-if-changed lib/gis/cordoba_series_percentage_repository.dart test/cordoba_series_percentage_repository_test.dart` — exit code 0; 2 archivos comprobados, 0 modificados. No se reescribió ningún archivo Dart.
- `git diff --check` — exit code 0; sin errores de whitespace (el chequeo abarca también cambios preexistentes del árbol).
- No se ejecutaron builds, benchmarks ni pruebas de dispositivo.

## Estado al cierre

El cambio de esta tarea es únicamente este informe nuevo. El suplemento, los dos GeoJSON, metadatos, tarjetas, PMTiles, reportes previos y modificaciones del usuario permanecen sin cambios por esta tarea. Rama `beta` y HEAD `299248598108992fd91cd88bef31d6d1da2a8a11`; sin operaciones de checkout, commit o push.

## Veredicto

**PERCENTAGE RECOVERY PARTIAL** — las seis recuperaciones exactas ya implementadas siguen respaldadas y las cifras actuales se reproducen; esta búsqueda no aportó nuevos porcentajes. Para avanzar, falta obtener copias primarias completas de las hojas sin publicación archivada y resolver la identidad cartográfica de las siete posiciones sin intersección. Los valores ausentes permanecen explícitamente sin estimar.
