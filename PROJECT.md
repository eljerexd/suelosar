# SuelosAR

## Visión del proyecto

SuelosAR es una aplicación SIG (Sistema de Información Geográfica) profesional para consultar las Cartas de Suelo del INTA de Argentina.

El objetivo es ofrecer una herramienta completamente offline, rápida y confiable para ingenieros agrónomos, estudiantes, técnicos e investigadores.

La aplicación debe priorizar:

* funcionamiento offline;
* rendimiento;
* precisión geográfica;
* arquitectura simple y mantenible;
* experiencia de usuario profesional.

---

# Estado actual

Actualmente el proyecto ya dispone de:

* Motor GIS propio.
* Renderizado vectorial mediante PMTiles + Mapbox Vector Tiles.
* Visualización interactiva de polígonos de suelo.
* Apertura de Cartas de Suelo en PDF.
* Selección de polígonos.
* Optimizaciones de rendimiento para grandes volúmenes de datos.
* Pipeline Docker para generar el mapa.

---

# Objetivos futuros

Prioridad alta:

* GPS offline.
* Mapa base de referencia offline.
* Buscador de series de suelo.
* Memorias descriptivas.
* Escala gráfica y herramientas cartográficas.

Prioridad media:

* Índice de productividad.
* Capacidad de uso.
* Favoritos.
* Marcadores.
* Medición de distancias.

Prioridad baja:

* IA para consultas sobre series de suelo.
* Estadísticas.
* Exportación.

---

# Tecnologías

* Flutter
* Dart
* PMTiles
* Mapbox Vector Tiles (MVT)
* SQLite
* Docker
* Tippecanoe
* Git

---

# Arquitectura

La aplicación está dividida en módulos.

lib/

* constants/
* data/
* gis/
* models/
* screens/
* services/
* widgets/

El módulo GIS es independiente del resto de la aplicación.

---

# Reglas de desarrollo

## No modificar el motor GIS

El motor GIS (PMTiles, renderer, cachés, decodificación, hit testing y optimizaciones) se considera estable.

No debe modificarse para agregar nuevas funcionalidades salvo que exista un error demostrado o una mejora importante de rendimiento.

---

## Cambios pequeños

Cada nueva funcionalidad debe implementarse mediante cambios pequeños y aislados.

Evitar refactorizaciones grandes.

---

## Offline First

Toda funcionalidad debe funcionar completamente offline.

No depender de servicios web para el funcionamiento normal.

---

## Rendimiento

Mantener el rendimiento del mapa como prioridad.

No introducir cambios que aumenten innecesariamente:

* tiempo de render;
* uso de memoria;
* reconstrucciones del mapa;
* decodificaciones repetidas.

---

## Arquitectura

No colocar lógica de negocio en main.dart.

Una pantalla por archivo.

Widgets reutilizables.

Servicios independientes.

Código limpio y documentado.

---

## Validación

Toda modificación debe finalizar con:

* flutter analyze
* flutter test

Cuando corresponda, verificar también la aplicación Windows o Android de forma manual.

---

## Regresiones

Si una nueva funcionalidad rompe una existente:

* restaurar primero el comportamiento anterior;
* luego reimplementar la funcionalidad con cambios mínimos.

Nunca solucionar una regresión mediante una refactorización completa si existe una alternativa más pequeña.

---

# Filosofía del proyecto

La prioridad no es agregar muchas funciones.

La prioridad es construir una herramienta estable, rápida y profesional que un ingeniero agrónomo pueda utilizar durante muchos años incluso sin conexión a Internet.

# Cómo implementar nuevas funcionalidades

Toda nueva funcionalidad debe seguir este orden:

1. Comprender la arquitectura existente.
2. Modificar únicamente los archivos necesarios.
3. Evitar refactorizaciones innecesarias.
4. Mantener compatibilidad con el motor GIS.
5. Verificar que no existan regresiones.
6. Ejecutar:
   - flutter analyze
   - flutter test
7. Probar manualmente la aplicación cuando el cambio afecte la interfaz o el mapa.

El objetivo es mantener una evolución incremental del proyecto, evitando cambios masivos que puedan romper funcionalidades existentes