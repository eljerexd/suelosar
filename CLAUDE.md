# CLAUDE.md

Este archivo complementa a AGENTS.md con reglas específicas para Claude Code
mientras dure la migración del motor GIS. Ante cualquier conflicto aparente
entre ambos archivos, las reglas de migración de este archivo tienen
prioridad sobre las reglas generales de "no modificar el motor GIS" de
AGENTS.md — pero solo dentro del alcance explícito de la migración.

---

## Contexto

SuelosAR está evaluando una migración del motor de renderizado GIS desde
`flutter_map` hacia un motor alternativo (candidato: MapLibre). Esta
migración se ejecuta en etapas, documentadas en AGENTS.md bajo
"GIS Engine Migration Status".

Ver la auditoría de estado inicial (2026-08-19) para el diagnóstico completo
de qué partes del código dependen de flutter_map y cuáles ya son
independientes del motor de renderizado.

---

## Reglas obligatorias mientras dure la migración

Hasta nuevo aviso del usuario, Claude debe:

1. **Analizar antes de modificar.** No tocar ningún archivo de `lib/gis/`
   sin primero explicar qué se va a cambiar y por qué, y en qué etapa del
   plan de migración corresponde ese cambio.
2. **No reemplazar flutter_map directamente.** No hacer swaps de
   `FlutterMap` por otro widget de mapa en un solo cambio. La sustitución
   del motor de renderizado ocurre recién en la Etapa 3 en adelante, y de
   forma incremental.
3. **No eliminar dependencias existentes.** No quitar `flutter_map`,
   `latlong2`, `pmtiles`, `vector_tile` ni ninguna otra dependencia GIS de
   `pubspec.yaml` sin instrucción explícita del usuario.
4. **No instalar dependencias nuevas** (MapLibre u otras) sin instrucción
   explícita del usuario para esa etapa puntual.
5. **No hacer migraciones globales de una sola vez.** Cada cambio debe ser
   pequeño, aislado y reversible, en línea con la política de "cambios
   pequeños" de AGENTS.md.
6. **Pedir confirmación antes de avanzar de una etapa a otra.** Terminar
   una etapa no autoriza a empezar la siguiente. Cada etapa se cierra con
   un resumen de lo hecho y una pregunta explícita antes de continuar.
7. **`gis_repository.dart` sigue protegido.** Es la capa de datos
   (PMTiles + MVT + caché) y ya es independiente del motor de renderizado.
   No se modifica salvo bug demostrado, incluso durante la migración.
8. **El motor actual debe seguir funcionando en todo momento.** Ningún
   cambio de una etapa puede dejar la app sin un mapa funcional. Si una
   etapa introduce una alternativa, la alternativa convive con
   flutter_map hasta estar validada — no lo reemplaza.

## Numeración de compilaciones de la aplicación

Antes de cada nueva compilación Flutter que genere o reemplace un binario de
la aplicación (Debug, Profile, Release, APK o ejecutable de Windows),
incrementar el sufijo numérico de `version` en `pubspec.yaml`, manteniendo
`major.minor.patch` igual salvo que también se esté cambiando la versión
SemVer. Ejemplo: `1.8.0+25` pasa a `1.8.0+26`. No reutilizar el número para
una nueva compilación: permite detectar arreglos publicados bajo la misma
versión SemVer y mantiene crecientes los identificadores de Android. Para
Windows, el build no debe superar 65535 por el límite de metadatos de versión.
Tests, análisis estático, hot reload y hot restart no generan un nuevo build.

Al preparar un release de Windows, usar la misma versión completa —incluido
el build— en el tag de GitHub, el instalador y su checksum; por ejemplo:
`v1.8.0+26`, `SuelosAR-Setup-1.8.0+26.exe` y
`SuelosAR-Setup-1.8.0+26.exe.sha256`.

## Qué SÍ está permitido sin pedir permiso adicional

- Investigación, lectura de documentación, y validación experimental en un
  proyecto Flutter aislado (fuera del árbol de SuelosAR) correspondiente a
  la Etapa 1.
- Proponer diseños o interfaces por escrito para revisión, sin
  implementarlos.
- Preguntar cuando algo no esté claro en vez de asumir.

## Estado actual del plan

- **Etapa 0 — Contexto:** en curso (este archivo y la actualización de
  AGENTS.md son parte de esta etapa).
- **Etapas 1 a 5:** no iniciadas.
