# Córdoba: acceso a publicaciones primarias y brechas de cobertura

Fecha: 2026-10-28  
Repositorio: `C:\Users\jerem\suelosar`  
Rama / HEAD: `beta` / `299248598108992fd91cd88bef31d6d1da2a8a11`

## Alcance y preservación

Se verificaron la ruta de trabajo, rama, HEAD, cambios staged/unstaged y archivos no rastreados antes de la investigación. La rama y HEAD coinciden con lo esperado. El árbol ya estaba modificado; se preservaron todos sus cambios y artefactos, incluidos `witch beta`, `.widget_preview/`, PMTiles, metadatos y suplemento de Córdoba, reportes y archivos de fuentes ignorados. No se usó ni creó un worktree. Esta tarea no cambió datos cartográficos, suplemento, código, configuración ni pruebas; el único archivo nuevo es este informe.

La búsqueda se limitó a registros bibliográficos/acceso de cuatro publicaciones priorizadas. No se volvieron a buscar porcentajes en los PDF individuales revisados previamente ni se descargaron publicaciones. Los catálogos y portales se consultaron solo para localizar ediciones, ejemplares y vías de acceso.

## Inventario actual

Recuento recalculado desde los dos GeoJSON de Córdoba, posiciones `serie_1..serie_8` no vacías en mayúsculas y suplemento actual cotejado por registro, símbolo, serie y fase:

| Escala | Elegibles | Porcentaje en WFS | Nulos WFS | Exactos en suplemento | Pendientes |
|---|---:|---:|---:|---:|---:|
| 1:50.000 | 2.642 | 2.462 | 180 | 6 | 174 |
| 1:100.000 | 576 | 465 | 111 | 0 | 111 |
| **Total** | **3.218** | **2.927** | **291** | **6** | **285** |

Las 285 posiciones se clasifican en **279 desconocidas individualmente**, **2 componentes de BYc3 con solo un agregado aproximado compartido** y **4 componentes EAr documentados como no estimables**. Los siete casos sin intersección cartográfica pertenecen a las 279 desconocidas; no son un grupo adicional. No se repartió el agregado de BYc3 ni se estimaron porcentajes para EAr.

## Adquisición de las cuatro publicaciones

### 3163-16 Miramar y 3163-22 Balnearia

- El inventario local de hojas IDECOR las registra a escala 1:100.000, año/edición `2012`, pero sin URL de página, PDF completo ni vínculo al repositorio; estado local `not verified`.
- Un ejemplar legible del **Catálogo de publicaciones de Cartas de Suelos de Córdoba (2017)**, atribuido en su portada al Ministerio provincial y EEA INTA Manfredi, lista ambas como `2013; 1:100.000`. Identifica localidades cubiertas y señala a Secretaría de Ambiente y EEA Manfredi como lugares de adquisición/consulta. El ejemplar consultado está alojado en Scribd, no en un dominio institucional: es una pista bibliográfica secundaria, no la memoria de suelos ni una copia primaria autenticada.
- Hay una discrepancia de año **2012 (índice WFS) frente a 2013 (catálogo 2017)**. No se puede determinar si refleja actualización del WFS, una edición distinta o error bibliográfico sin portada/colofón de la publicación y relación con los registros cartográficos.
- En las búsquedas focalizadas por código y nombre exactos no se localizó una memoria digital primaria completa en el portal provincial, repositorio INTA ni catálogos universitarios consultados. Esto no demuestra que no exista digitalización fuera de esas rutas.
- Posiciones pendientes asociadas por intersección (no porcentajes inferidos): Miramar 3163-16: `MGtc-2` (3) y `MOtc-11` (4); Balnearia 3163-22: `MNtc-9` (3), `Ip1` (3), `MOtc-11` (4) y `RII1` (4). Son 17 posiciones únicas; `MOtc-11` aparece en ambas hojas candidatas y se cuenta una sola vez.
- **Ruta concreta:** consultar a Biblioteca EEA INTA Manfredi, cuya ficha del Censo Nacional de Bibliotecas Gubernamentales identifica el correo `eeamanfredi.cd@inta.gob.ar`, teléfono (3572) 49-3053 y dirección Ruta Nacional 9 km 636, Manfredi. También consultar a la Secretaría provincial en Av. Richieri 2187, Córdoba, teléfono 0351-434-3310/14, datos publicados en el catálogo 2017. Pedir que confirmen título/edición e identifiquen si tienen ejemplar o digitalización autorizada.

### 3363-11 Leones

- Título confirmado por el catálogo institucional CRAI UES21: *Carta de Suelos de la República Argentina: hoja 3363-11 Leones*, INTA, Córdoba, 1979; 87 páginas con mapas, cuadros y gráficos, más cuatro mapas.
- UES21 enumera los mapas anexos: hoja `3363-11-1 Noetinger`, `3363-11-2 Saira`, `3363-11-3 Leones` y `3363-11-4 Colonia Moreno`. Es un conjunto de hojas suplementarias cartográficas, no cuatro porcentajes ni cuatro ediciones.
- **Ejemplar físico disponible:** Biblioteca Campus UES21, signatura `631.4 (82) In61le`, copia 1, código F00031. El registro no ofrece descarga digital ni indica que se haya autorizado escaneo.
- **Segundo ejemplar físico disponible:** Biblioteca Central Vicerrector Ricardo Podestá, UNVM, signatura `G 5351.J3 LEO`, sección Folletos. El catálogo lo describe como impreso y atribuye publicación 1979 a INTA/CIRN y Secretaría de Agricultura y Ganadería.
- **Ruta de acceso:** solicitar consulta o reproducción permitida a UES21 (`biblioteca@ues21.edu.ar`, Bv. Los Latinos 8555, Córdoba, teléfono +54 351 4757512) y a UNVM (`bccirculacion@rec.unvm.edu.ar`, Arturo Jauretche 1555, Villa María, teléfono +54 353 4539144). El objetivo documental concreto son las descripciones de unidades `SEl` y `SEl1`, las páginas/tablas del capítulo de suelos que indiquen composición, y portada/colofón. Solicitar específicamente que indiquen si pueden facilitar digitalmente esas páginas y bajo qué condiciones.
- **Disponibilidad digital:** no se encontró una copia íntegra primaria accesible. La ficha de catálogo física no debe confundirse con un PDF digital.

### 3563-15 Emilio V. Bunge

- El inventario local IDECOR registra hoja `3563-15`, escala 1:50.000, año 2000, título normalizado `EMILIO V. BUNGE`, sin URL de página o PDF completo.
- La búsqueda por el código exacto, nombre completo y variantes en el catálogo provincial 2017, Repositorio INTA y catálogos universitarios consultados no produjo un registro verificable de este título ni un ejemplar. El catálogo 2017 no contiene una entrada coincidente con “Emilio V. Bunge”. No se concluye que la publicación no exista.
- La posición pendiente candidata es `LRc2`, serie `LA RENANCÓ` (un registro/una posición). La intersección del índice es solo una hoja candidata; no demuestra por sí sola la edición fuente del registro WFS.
- **Ruta concreta:** consultar a Biblioteca EEA INTA Manfredi (`eeamanfredi.cd@inta.gob.ar`, (3572) 49-3053) y a la Secretaría provincial (Av. Richieri 2187, 0351-434-3310/14). Pedir búsqueda por `3563-15`, `Emilio V. Bunge`, 1:50.000, año 2000; confirmar portada, colofón, signatura/localización y si existe ejemplar consultable o copia digital autorizada. Incluir `LRc2 / LA RENANCÓ` como clave de búsqueda, no como prueba de contenido.

### Resultado de las búsquedas digitales

No se localizó ni abrió una copia primaria completa nueva de Miramar, Balnearia, Leones o Emilio V. Bunge. Para Leones la ruta física sí está documentada por dos catálogos institucionales. Para Miramar/Balnearia hay una referencia de catálogo alojada por un tercero, con año diferente al del WFS. Para Emilio V. Bunge no se localizó una ficha de holding; la ruta más realista es una consulta directa a los custodios del catálogo provincial/INTA. No se extrajo ni incorporó ningún porcentaje nuevo.

## Siete posiciones sin intersección de hoja

Se comparó el registro de unidad de 1:50.000 con la capa local de límites oficiales `cartas_provincia_2024_20261026.json`, mediante intersección geométrica (no cercanía). Los tres registros existen, tienen geometría y un identificador `id` estable. Los registros de unidades no incluyen una propiedad de hoja/edición fuente; ninguno intersecta una hoja del índice en esa escala.

| Registro y símbolo | Posición pendiente | Geometría / ID | Resultado del cruce y qué falta |
|---|---|---|---|
| `1153`, `CoI` | CALAMUCHITA III (1) | Polígono presente; `id=1153`. bbox `[-64.50079568,-31.97314969,-64.46560835,-31.66641418]`. | Sin intersección con los polígonos de hoja 1:50.000; el registro no tiene clave de hoja. La hoja 3363-1 Río Tercero es solo la caja envolvente cartográfica más cercana con separación aproximada de 0,027°; no intersecta y no se asigna. Falta la relación oficial registro↔hoja/edición o un límite corregido/documentado. No prueba por sí solo que la geometría esté mal. |
| `1392`, `Co84` | SENDERO LUJÁN I y SENDERO LUJÁN II (2) | Polígono presente; `id=1392`. bbox `[-64.50001594,-31.31801335,-64.46575600,-31.20530641]`. | Sin intersección y sin clave de hoja en el registro. 3163-13 Jesús María queda a unos 0,205° entre cajas envolventes; no es base para asignación. Falta identificador cartográfico oficial o aclaración de cobertura/edición. |
| `1393`, `ERs2` | EL ROSARIO; ALTO GRANDE en fase moderadamente inclinada; PUESTO JACINTO; CERRO NEGRO (4) | Polígono presente; `id=1393`. bbox `[-64.47214687,-31.19058627,-64.43987554,-31.15736546]`. | Sin intersección y sin clave de hoja. 3163-13 Jesús María queda a unos 0,157° entre cajas envolventes; no se asigna por proximidad. Falta correspondencia oficial registro↔hoja/edición y documento primario que resuelva la composición. |

Por tanto, no falta un feature, su geometría ni el identificador interno de unidad. Lo que no está establecido es **qué publicación/hoja y edición documenta estas unidades**, y por separado el porcentaje individual de las series. Con lo disponible no se distingue entre un vacío real de cobertura del índice de hojas, una geometría de límite incompleta/desfasada o una asignación fuente distinta. La observación mínima resolutiva es una relación oficial de esos `id`/símbolos con código de hoja y edición (metadato del WFS fuente o índice editorial), o una cartografía/fe de erratas oficial que explique la discrepancia. No se propone trasladar ni corregir geometrías.

Los siete casos se relacionan temáticamente con series que aparecen en mapas de hojas cercanas o conocidas, pero compartir un nombre de serie no prueba que el registro pertenezca a esa publicación. No se consultó ningún “candidato cercano” como fuente asignada ni se atribuyeron porcentajes a partir de él.

## Solicitud bibliográfica lista para enviar (no enviada)

**Asunto:** Consulta de ejemplares y reproducción de páginas — Cartas de Suelos de Córdoba

> Estimadas/os responsables de Biblioteca / Cartas de Suelos:
>
> Estoy verificando, con cita y correspondencia exacta de hoja, los datos de composición de unidades cartográficas de las Cartas de Suelos de Córdoba para una aplicación educativa. ¿Podrían indicarme si poseen ejemplares consultables o copias digitales autorizadas de las siguientes publicaciones y cuál es el procedimiento aplicable para consultar o reproducir únicamente las páginas necesarias?
>
> - Hoja 3363-11 Leones, INTA, 1979 (1:50.000; catálogo UES21: 87 páginas y cuatro mapas: 3363-11-1 Noetinger, -2 Saira, -3 Leones y -4 Colonia Moreno). Interesan las descripciones/tablas de las unidades SEl y SEl1 y las páginas donde se indique la participación de sus series, además de portada y colofón.
> - Hojas 3163-16 Miramar y 3163-22 Balnearia, catalogadas en una referencia provincial de 2017 como 2013, 1:100.000, mientras que el índice WFS IDECOR local consigna 2012. Agradecería confirmar título, año/edición y disponibilidad de la memoria completa, en particular las descripciones de MGtc-2, MOtc-11, MNtc-9, Ip1 y RII1, además de portada/colofón.
> - Hoja 3563-15 Emilio V. Bunge, registrada por IDECOR como 1:50.000, año 2000. Agradecería confirmar si existe la publicación, su título/edición y disponibilidad; interesa la descripción de LRc2 (LA RENANCÓ), las páginas/tablas de composición y portada/colofón.
>
> No solicito una estimación de porcentajes. Solo usaré proporciones expresamente declaradas en la fuente, y citaré institución, edición, página/sección y texto pertinente. Si no es posible enviar copias, agradecería instrucciones para consulta presencial, préstamo interbibliotecario o reproducción autorizada. Muchas gracias.

La solicitud está preparada para los contactos bibliotecarios indicados arriba. No se envió ningún correo ni se solicitó acceso en nombre del usuario.

## Fuentes consultadas y persistencia

- Catálogo CRAI UES21, ficha de Leones 3363-11, año, descripción, cuatro mapas, signatura/estado y contacto institucional: [registro bibliográfico](https://biblio.uesiglo21.edu.ar/bib/6826).
- Catálogo PICA de Biblioteca Central UNVM, ficha/listado de Leones 3363-11 impreso, 1979, signatura `G 5351.J3 LEO`, disponible; contacto institucional en la portada del catálogo: [registro UNVM](https://biblio.unvm.edu.ar/opac_css/index.php?id=139&l_typdoc=&lvl=categ_see&nb_per_page_custom=200&nbr_lignes=4503&page=12) y [portal/contacto](https://catalogo.unvm.edu.ar/index.php?id=4114&lvl=categ_see).
- IDECOR explica que las cartas digitales se consultan en el portal provincial y GeoINTA y que el catálogo proporciona rutas para acceso/consulta: [¿Qué son las Cartas de Suelo?](https://www.idecor.gob.ar/que-son-las-cartas-de-suelo/).
- Catálogo provincial 2017 consultado como referencia bibliográfica, alojado en tercero; listas Miramar/Balnearia con año 2013, escala y direcciones de adquisición, pero no es la publicación primaria: [catálogo de 2017](https://es.scribd.com/document/467801954/Cartas-de-Suelos-2017-pdf).
- Biblioteca EEA INTA Manfredi: domicilio, horario, teléfono y correo `eeamanfredi.cd@inta.gob.ar` registrados en el [Censo Nacional de Bibliotecas Gubernamentales 2021](https://www.argentina.gob.ar/sites/default/files/informe_del_censo_nacional_de_bibliotecas_gubernamentales.pdf), página impresa 56 (página PDF 55). La [ficha vigente de EEA Manfredi](https://www.argentina.gob.ar/inta/cr-cordoba/eea-manfredi) confirma dirección y línea de trabajo “Mapas de Suelos”.
- Capa oficial de hojas IDECOR archivada localmente: `data/provinces/cordoba/source/gis/cartas_provincia_2024_20261026.json`, hash conservado en `SOURCES.md`; WFS de unidades y listado de pendientes descritos en los informes previos bajo `docs/`.
- Bibliografía secundaria sobre Leones no se usó para recuperar porcentajes. Un artículo puede citar composición de `Co10`, pero ese símbolo no es uno de los pendientes `SEl`/`SEl1`; además, una cita secundaria no sustituye la página de la publicación primaria.

## Hashes, cambios y validación

Hashes SHA-256 de datos verificados en esta tarea, sin cambios:

| Archivo | SHA-256 |
|---|---|
| `data/provinces/cordoba/source/gis/carta_suelo_50mil_2025.json` | `280e3de24dbcfe7e3fbb1fcb74318b73e2a5c42a47f33e4c7a9e72b1902a2c13` |
| `data/provinces/cordoba/source/gis/carta_suelo_100mil_2025.json` | `a338767d901a42dbd16ddbda8eea365e1bcaf63ebca6220230791fe7395ecc0b` |
| `assets/data/cordoba_series_percentage_supplement.json` | `a090d91bc06a81d4be589023e9be3bdc4b1d70b3dd3b8a1502bc22b24d2c5c4e` |
| `data/provinces/cordoba/source/gis/cartas_provincia_2024_20261026.json` | `fdda41db80f46de65734f3fedf36ff98f9db26e38057f1f714b42fe7a5cd4ceb` |
| `docs/CORDOBA_PERCENTAGE_PENDING_POSITIONS_20261026.csv` | `3e11a31b4346ff9abdc2dfd1568c2e1b7578536eb5f71cc4856555295da4d4f1` |

- Datos, metadatos, suplemento y CSV: sin cambios.
- Porcentajes nuevos: ninguno; no hay evidencia primaria suficiente.
- Tests Flutter/Dart: no ejecutados; no hubo cambios funcionales ni de datos.
- Validación pendiente al cierre: `git diff --check` tras añadir este informe y verificación final de hashes/estado Git. No se afirma haber corrido esas comprobaciones antes de su ejecución.
- No se ejecutaron builds, benchmarks, consultas a dispositivos ni experimentos de rendimiento.

## Próximo paso justificable

Enviar (cuando el usuario lo decida) la solicitud bibliográfica a EEA Manfredi, UES21 y UNVM. Para 3363-11 ya existe una ficha de ejemplar físico localizable; para Miramar/Balnearia hay que resolver además la discordancia 2012/2013; para 3563-15 primero se requiere confirmar que existe un ejemplar y su edición. Al recibir copias, conservar los originales con institución, URL/procedencia, fecha, edición y SHA-256; solo entonces revisar páginas exactas y actualizar el suplemento si una fuente primaria identifica símbolo, escala, serie, fase y proporción.

Para las siete posiciones sin hoja intersectada, obtener la clave oficial de hoja/edición asociada a los ids `1153`, `1392` y `1393` antes de buscar una publicación o modificar geometrías. No se justifica asignar hojas por cercanía.

**Veredicto: PERCENTAGE RECOVERY PARTIAL** — inventario reproducido; vías de acceso concretas documentadas; ninguna copia primaria nueva ni porcentaje adicional fue localizado. Las siete posiciones sin intersección continúan sin atribución cartográfica demostrada.
