# Auditoría de tarjetas de detalle GIS: Buenos Aires y Córdoba

Fecha: 2026-10-25  
Repositorio: `C:\Users\jerem\suelosar`  
Alcance: diagnóstico estático de datos, mapeo, modelo y widgets. No se modificó código ni se ejecutaron pruebas.

## A. Diagnóstico ejecutivo

Las provincias usan el mismo flujo y la misma tarjeta inferior. La diferencia principal no es un componente Córdoba separado: es el significado y contenido de sus propiedades.

1. **Porcentajes en el título (confirmado):** el mapeo Córdoba asigna el campo fuente `nombre` a `Nombre_UC`; en el registro `E23/17`, `nombre` contiene una narración completa con `40%`, `30%`, `15%` y `15%`. `_showFeatureAttributes` presenta `Nombre_UC` literalmente como título. Esos porcentajes son proporciones de componentes de la unidad, no parte de un nombre breve. El mismo registro también los conserva correctamente como `SERIE1..4` y `PORC1..4`, que la tarjeta muestra en “Series de suelo”. La tarjeta duplica la composición en el título y en la sección de series.
2. **Paisaje (el supuesto desplazamiento no queda confirmado):** el WFS Córdoba 1:50k y 1:100k no tiene un campo de paisaje, según la configuración y el informe del pipeline. La tarjeta coloca `PAISAJE` bajo la sección “Paisaje”; para estas coberturas recibe null y `_readAttribute` lo presenta como “Sin datos”. No hay evidencia de que una propiedad de paisaje se lea de otra clave ni de que el widget la coloque en otra sección. La narración de `nombre` contiene fases/descriptores de componentes, pero no se debe reinterpretar como `PAISAJE`.
3. **Series Córdoba 1:100k omitidas (confirmado):** el mapeo y los datos normalizados conservan `SERIE7` y `SERIE8`, pero `GisSoilSeries.fromProperties` itera solo de 1 a 6. Los nombres de esas posiciones nunca llegan a las tarjetas. La fuente no publica `PORC7/PORC8`; no se debe inventar esos porcentajes.
4. **Campos taxonómicos 1:500k no presentados (confirmado en el trayecto actual de tarjeta):** los datos/configuración preservan `IP`, `SUBGRUPO1..5` y `POSICION1..5`, separados correctamente de las series. La tarjeta de detalle solo presenta símbolo, tipo, capacidad, paisaje, series y memorias. El decoder MVT conserva propiedades genéricas, pero la tarjeta no representa estos campos taxonómicos ni `porc_1..5` como proporción de subgrupo. No se deben reciclar `PORCn`, que significa proporción de serie.

No se pudo inspeccionar una tarjeta ejecutándose: `adb` no está disponible en el entorno actual. En consecuencia, las conclusiones son de código y datos; no se afirma validación visual en un teléfono o emulador.

## B. Comparación

| Campo | Buenos Aires | Córdoba 1:50k / 1:100k | Córdoba 1:500k | Comportamiento esperado / hallazgo |
|---|---|---|---|---|
| Título / `Nombre_UC` | Nombre conciso en el ejemplo: “Asociacion Alta Vista 3”. | Mapeado desde `nombre`; puede ser prosa extensa con composición y porcentajes. En `E23/17`, el título contiene toda la descripción de cuatro componentes. | No existe `Nombre_UC` en la fuente; el esquema lo deja null. | Un campo de nombre no debería convertirse accidentalmente en el encabezado de una narración. Mantener la narración disponible en una sección descriptiva y un encabezado breve basado solo en datos existentes. En la tarjeta inferior y el panel de escritorio se usan reglas de título distintas.
| Símbolo (`SIMBC`) | `AVi3` en el ejemplo. | Desde `pdf_simbolo`; puede faltar para polígonos que no son unidades de suelo. | Desde `pdf_simbolo`. | La ausencia de símbolo es propia del registro; no inferirlo desde el nombre.
| Tipo (`TIPO`) | `Asociacion`. | Desde `tipo_unida`. | Desde `tipo_un`. La configuración documenta equivalencia de vocabulario entre fuentes. | El campo se muestra en el subtítulo y en información general. No se encontró evidencia de mapeo incorrecto.
| Capacidad (`CAP_USO`) | `IVs`. | Desde `cu`. | Desde `cu`. | Se muestra como capacidad de uso. Los nulos de fuentes no deben rellenarse por inferencia.
| Paisaje (`PAISAJE`) | En el ejemplo: “Lomas planas con suaves ondulaciones”. | No disponible en ambos WFS; configuración declara ausencia y null. La tarjeta mostrará “Sin datos” bajo “Paisaje”. | Desde `paisaje`; sí existe en esta escala. | La colocación del campo existente es correcta en el widget. El texto genérico “Sin datos” no explica que la fuente no provee este atributo. No trasladar fases de componentes a paisaje.
| Series y proporciones | `Alta Vista` 70%, `Estancia Los Manantiales` 30% en los datos normalizados. | Se mapean `serie_1..6`/`serie_1..8` y `porc_1..5`; `PORC6` no existe. `E23/17`: 40/30/15/15. | No hay series nombradas ni proporciones de serie. | La tarjeta tiene una sección apropiada para series y porcentaje. No mostrar porcentaje ausente como cero ni asignar `porc_1..5` taxonómico a `PORCn`.
| Series 7/8 | No declaradas en su esquema, que llega a 6. | Existen en 1:100k y se conservan en propiedades; la configuración documenta cuatro unidades que las usan. 1:50k no las tiene. | No aplica: la fuente no tiene series. | El límite global de seis del parser provoca pérdida en Córdoba 1:100k. La arquitectura debe respetar el rango presente en cada cobertura sin fabricar porcentajes.
| Fases/descripción de componentes | El ejemplo no exige fases dentro del nombre. | La fuente 1:50k puede traer `fase_1..4`; el mapeo no las conserva como campos dedicados. Parte de la prosa está embebida en `nombre`, como “en fase moderada a severamente erosionada”. | No son parte del esquema de series. | Si se acorta el encabezado, conservar la descripción original o mapear fases con semántica explícita; no descartarlas.
| Taxonomía (`IP`, subgrupo, posición) | No forma parte del ejemplo ni de este esquema de unidad. | No es parte del mapeo principal documentado para estas escalas. | `IP`, `SUBGRUPO1..5`, `POSICION1..5` se preservan. `porc_1..5` significa proporción de subgrupo. | La tarjeta actual no presenta estos datos. Si se muestran, deben ir en una sección taxonómica separada, con sus porcentajes en campos propios.
| Ausencias y formato | La tarjeta representa propiedades faltantes como “Sin datos”. | Hay ausencias de origen (paisaje, porc6) y ausencias por registro (Nombre_UC, series, etc.). | Nombre y series son ausentes por diseño de esa fuente. | La presentación no distingue “no informado” de “no aplicable/no disponible en esta fuente”. No inventar valores.

**Ejemplos examinados:** Buenos Aires, `OBJECTID=175`, normalizado; Córdoba 1:50k, `SIMBC=E23/17`, `OBJECTID=68`, normalizado; Córdoba 1:100k, ejemplos con `SERIE7/8` (por ejemplo `CoD1`, `CoJ`, `CoH1`) presentes en el archivo normalizado. Córdoba `OBJECTID=288` también existe, pero es un registro sin propiedades temáticas en el archivo normalizado inspeccionado; no es un ejemplo adecuado de unidad edáfica y no se usa para atribuir síntomas.

## C. Hallazgos confirmados

### 1. Narración de `nombre` presentada como título

- **Severidad: alta.**
- **Ejemplo:** Córdoba 1:50k `E23/17`, `OBJECTID=68`. `Nombre_UC` normalizado: “Complejo de Series EL VEINTITRÉS 40%; HUINCA RENANCÓ en fase moderada a severamente erosionada 30%; EL VEINTITRÉS variante calcárea 15% y EL PEQUÉN 15%”. La misma feature tiene `SERIE1..4` y `PORC1..4` con nombres y proporciones correspondientes.
- **Causa:** mapeo `Nombre_UC: from nombre` y título inferior `_readAttribute(feature, 'Nombre_UC')` presentado sin transformación.
- **Referencias:** `data/provinces/cordoba/province.yaml:52-71`; `lib/gis/gis_map_screen.dart:5692-5730`.
- **Matiz:** no es correcto borrar los porcentajes del dato fuente ni de la composición de series. Debe separarse encabezado de descripción, preservando el texto descriptivo en una sección etiquetada.

### 2. La sección de paisaje aparece aunque el atributo no está disponible

- **Severidad: media (claridad), no defecto de ubicación demostrado.**
- **Fuente:** Córdoba 1:50k/1:100k declara `PAISAJE` ausente; el pipeline reporta 1.959 features y `PAISAJE` ausente para la 1:50k.
- **Causa visual inferible desde el código:** `_showFeatureAttributes` siempre crea la sección “Paisaje”; `_readAttribute` convierte null/vacío a “Sin datos”; `_LandscapeDescription` presenta “Descripción” y ese valor.
- **Referencias:** `data/provinces/cordoba/province.yaml:55-59, 125-133`; `data/provinces/cordoba/output/report.md:31-47`; `lib/gis/gis_map_screen.dart:5767-5791, 5916-5919, 6121-6146`.
- **Conclusión limitada:** la fuente no permite afirmar que la descripción de paisaje esté colocada mal; para estas escalas no hay tal campo. En 1:500k sí se mapea `paisaje` y el componente la pone bajo el título “Paisaje”. La apariencia concreta requiere una captura runtime, no disponible.

### 3. `SERIE7/8` de Córdoba 1:100k descartadas por el parser común

- **Severidad: alta para las unidades afectadas.**
- **Evidencia:** configuración 1:100k mapea `serie_1..serie_8`; documenta cuatro features con series 7/8. En el `normalized.geojson` inspeccionado hay features con `SERIE7/8` (tres ejemplos observados; no se infiere el universo completo a partir de ese muestreo).
- **Causa:** `GisSoilSeries.fromProperties` itera `index <= 6`. Como las tarjetas consumen esta lista, los nombres adicionales se pierden en el UI aunque el decoder MVT conserva las propiedades presentes.
- **Referencias:** `data/provinces/cordoba/province.yaml:120-136`; `lib/gis/gis_soil_series.dart:19-37`; consumo en `lib/gis/gis_map_screen.dart:5705-5707, 5792-5806`; decoder en `lib/gis/gis_repository.dart:520-526`.
- **Límite semántico:** la configuración declara que no existe `PORC7/8`; presentar “Sin porcentaje” para esos nombres es más correcto que inventar una proporción.

### 4. Campos taxonómicos 1:500k preservados pero no incluidos en la tarjeta

- **Severidad: media.**
- **Evidencia:** configuración mapea `IP`, `SUBGRUPO1..5` y `POSICION1..5`; el reporte del pipeline indica que esos atributos se conservan en PMTiles. La tarjeta actual solo renderiza símbolo, tipo, capacidad, paisaje, series y vínculos a memorias.
- **Causa:** no hay una sección taxonómica en `_showFeatureAttributes`; `PORC1..6` deliberadamente no se usan para estos campos porque su semántica es porcentaje de serie, mientras `porc_1..5` de 500k es porcentaje de subgrupo y hoy no tiene propiedad de destino propia.
- **Referencias:** `data/provinces/cordoba/province.yaml:155-178`; `data/provinces/cordoba/output/report.md:79-90`; `lib/gis/gis_map_screen.dart:5767-5852`; `lib/gis/gis_repository.dart:520-526`.
- **Limitación:** la confirmación en tarjeta en tiempo de ejecución requiere un feature PMTiles cargado y captura; el hallazgo de omisión se basa en las propiedades/configuración y el conjunto de campos que el widget consume.

### 5. Títulos inconsistentes entre vista compacta, panel de escritorio y tarjeta

- **Severidad: baja/media.**
- **Evidencia:** la tarjeta inferior usa `Nombre_UC`; el panel escritorio prefiere el primer nombre de serie y muestra `Nombre_UC` por separado; la vista previa usa el primer nombre de serie.
- **Referencias:** `lib/gis/gis_map_screen.dart:5712-5730`, `8291-8327`, `10420-10455`.
- **Efecto:** en Córdoba un encabezado puede ser una narración con porcentajes en una vista y un nombre de serie en otra; no hay una regla única de identidad de unidad. No es un fallo de porcentaje calculado: es una diferencia de presentación/selección del campo.

## D. Datos ausentes frente a pérdidas de integración

**Ausencias reales de fuente/esquema:** `PAISAJE` en WFS 1:50k y 1:100k; `PORC6` y `PORC7/8` en las fuentes indicadas; `Nombre_UC` y series con nombre en 1:500k. Deben quedar ausentes, con una explicación de disponibilidad, no completarse con datos inferidos.

**Pérdidas confirmadas en la presentación:** `SERIE7/8` de 1:100k se elimina al crear `GisSoilSeries`; los campos de taxonomía 1:500k no se muestran en las secciones actuales; `fase_1..4` no tienen destino estructurado en el esquema 50k, aunque parte de esa información sobrevive dentro de `nombre`.

**No demostrado:** que el widget coloque un valor PAISAJE válido en la sección equivocada; que porcentajes estén calculados mal; que se deba extraer una subcadena concreta para generar un nombre corto; o que todos los features Córdoba tengan los mismos campos. La tarjeta runtime tampoco fue inspeccionada.

## E. Plan mínimo de corrección

No se implementó nada. Para una corrección posterior, el conjunto mínimo probable es:

1. **`lib/gis/gis_map_screen.dart`:** separar el encabezado de una descripción larga; mantener intactos los nombres/proporciones en “Series de suelo”; incluir la prosa original bajo una sección con nombre semánticamente correcto, sin llamarla paisaje. Evitar la sección de paisaje vacía cuando la propiedad no existe, o explicar que no está disponible en la fuente. Unificar la regla de encabezado en la tarjeta inferior, panel de escritorio y vista previa sin perder la identidad de unidad.
2. **`lib/gis/gis_soil_series.dart`:** aceptar un límite/representación que preserve todas las posiciones de serie válidas para la fuente/cobertura, sin asignar `PORC7/8` inexistentes. La lista de series podría permitir porcentaje vacío.
3. **Modelo y mapping de Córdoba (solo si se decide mostrar taxonomía):** añadir campos tipados y distintos para descripción/fases, `IP`, subgrupo, posición y porcentaje de subgrupo. No mapear porcentaje de subgrupo a `PORC`; no alterar datos de Buenos Aires.
4. **Tests:** fixtures reales representativos por escala y una fixture BA para demostrar el comportamiento común y la falta de regresión.

La arquitectura puede conservar el widget compartido. Requiere un mapeo/presentación consciente de escala/cobertura para diferenciar serie edáfica de taxonomía; no justifica duplicar toda la tarjeta por provincia.

## F. Regresiones que faltan cubrir

- Widget test con el registro Córdoba `E23/17`: título compacto/no narrativo y narración original accesible en un campo descriptivo; los cuatro nombres y porcentajes permanecen exactos en composición.
- Modelo/parser: `SERIE7/8` visibles para Córdoba 1:100k, porcentajes vacíos cuando la fuente no los entrega; BA conserva su rango de seis y sus resultados actuales.
- Widget test con `PAISAJE` válido (BA y Córdoba 1:500k): aparece bajo la sección Paisaje; con null (Córdoba 1:50k/1:100k), no se representa como una descripción inventada.
- Test de taxonomía 1:500k: `IP`, subgrupos, posiciones y proporciones taxonómicas quedan etiquetados separadamente de series/PORC.
- Test de propiedades faltantes y orden/acento/format para `SIMBC`, `TIPO`, `CAP_USO` y valores ausentes.
- Test de consistencia del encabezado entre tarjeta inferior, panel de escritorio y vista previa.

Los tests existentes inspeccionados cubren parseo básico de `SERIE1..6`/porcentajes (`test/widget_test.dart:479-499`) y una tarjeta de búsqueda genérica (`:2320-2358`), pero no estos casos Córdoba por escala. No se ejecutó ningún test en esta auditoría.

## G. Verificación, límites y conclusión

- Rama observada: `beta`; HEAD: `299248598108992fd91cd88bef31d6d1da2a8a11`.
- Estado sucio preexistente preservado: cambios en el mapa/repository/configuración y tests Córdoba/Santa Fe, `docs/cordoba_gis_profile_2026-10-16.md`, `release-symbols/`, y `witch beta`, entre otros. El único archivo nuevo de esta auditoría es este informe.
- No se hicieron cambios a código, tests, PMTiles, datos fuente ni configuración. No se ejecutaron builds, pruebas ni benchmarks. `adb` no está disponible, por lo que no hubo inspección visual runtime.
- Buenos Aires y Córdoba pueden usar el mismo componente para los campos semánticamente comunes. La integración Córdoba no está completa en presentación mientras se trunque `SERIE7/8`, se use prosa larga como título y no se presenten o expliquen los campos específicos de paisaje/taxonomía por escala.

### Referencias principales

- `lib/gis/gis_map_screen.dart:5692-5806` — hoja de detalles y secciones.
- `lib/gis/gis_map_screen.dart:5916-5919` — valor ausente convertido a “Sin datos”.
- `lib/gis/gis_map_screen.dart:6121-6187` — widgets de paisaje y series.
- `lib/gis/gis_map_screen.dart:8291-8327, 10420-10455` — encabezados alternativos.
- `lib/gis/gis_soil_series.dart:19-37` — parser limitado a seis.
- `lib/gis/gis_repository.dart:520-526` — copia genérica de propiedades vectoriales.
- `data/provinces/buenos_aires/province.yaml:13-27` — mapeo BA.
- `data/provinces/cordoba/province.yaml:48-76, 120-136, 155-178` — esquemas Córdoba por escala y separación semántica.
- `data/provinces/cordoba/output/report.md:31-47, 79-90` — cobertura y atributos preservados.
- `test/widget_test.dart:479-499, 2320-2358` — cobertura de pruebas existente.

