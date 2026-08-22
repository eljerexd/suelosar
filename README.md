# suelosar

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.



Hoy SuelosAR ya tiene:

✅ Cartas de suelo offline.
✅ Visualización GIS.
✅ Búsqueda.
✅ Marcadores personales.
✅ Favoritos.
✅ Mediciones.
✅ Análisis de lote.
✅ Exportación PDF.
✅ Exportación GeoJSON.
✅ Exportación CSV.
✅ Responsive.
✅ Accesibilidad.
✅ Optimizaciones.
✅ 63 tests.
✅ Auditorías funcionales, UX y performance.

AUDITORIA

Auditoría GIS (la más importante)

Conclusiones verificadas:

✅ El sistema LOD ya existe y funciona (≈50 % menos vértices en z9).
✅ GisMapScreen no reconstruye durante el paneo.
✅ Las etiquetas no son el cuello de botella (~0,7 ms).
✅ PMTiles tampoco limita el paneo cuando los tiles ya están en caché.
✅ No hay fugas de memoria observadas.
✅ El cuello de botella confirmado es el renderizado raster de PolygonLayer de flutter_map.
✅ Se renderizan aproximadamente 145.000 vértices visibles (≈185.000 vértices fuente procesados por frame).
✅ El costo está en getOffsetsXY, areOffsetsVisible, VisibleSegment y drawPath().
✅ Restaurar el painter oficial de flutter_map eliminando la instrumentación dio una mejora aproximada del 40 %.
✅ useAltRendering fue probado y descartado porque empeoró el rendimiento.
✅ No se justifica seguir haciendo auditorías generales sobre este tema sin un cambio importante en la arquitectura.

*FEATURES 19/07/2026

✅ 1. Optimización de UI (implementada)

Se mejoró el rendimiento interno de las pantallas (excepto GIS):

ValueNotifier + ValueListenableBuilder para búsquedas.
Índices de búsqueda precalculados.
Favoritos usando Set.
Eliminación de AutomaticKeepAlive innecesarios.
Menos asignaciones en listas.
TweenAnimationBuilder optimizado en Home.

Resultado:

Código más eficiente.
Las búsquedas son más rápidas.
La sensación general de scroll prácticamente no cambió.
✅ 2. Auditoría de robustez (implementada)

Se corrigieron problemas reales:

Sincronización O(n²) → operaciones por lote.
Favoritos virtualizados (SliverList).
Eliminación del polling de sincronización.
Smoke test de Windows actualizado.

Además se agregaron pruebas de estrés:

10.000 marcadores.
5.000 mediciones.
5.000 favoritos.
10.000 operaciones de sincronización.
Escrituras concurrentes.
Redimensionado.
Montaje/desmontaje repetido.

Resultado:

141 tests pasando.
✅ 3. Migración del visor PDF (implementada)

Ya quedó completamente terminada.

Se migró de:

Syncfusion

a:

pdfrx

Incluyendo:

zoom 25–500%
Fit Width
Fit Page
scrollbar escritorio
pinch correcto Android
páginas centradas
eliminación del fork de Syncfusion
✅ 4. Auditoría GIS (implementada)

No fue una optimización a ciegas.

Se ejecutó un perfil completo en Flutter Profile.

Conclusiones:

LOD funciona correctamente.
Labels no son el problema.
Build no reconstruye.
PMTiles no limita el paneo.
No hay fugas.
✅ 5. Mejora real del GIS (implementada)

Durante la auditoría se descubrió algo importante:

Había quedado instrumentación de profiling dentro del painter de flutter_map.

Se restauró el painter oficial.

Resultado:

FPS:
5.05

↓

7.10

≈40 % de mejora.

Sin cambiar ninguna funcionalidad.


🔴  `flutter build apk --release` (sin flavor ni dart-define) compila igual pero
la app queda sin Supabase configurado ("Servicio no está configurado"). Android
tiene flavors (`prod` / `beta`) y ninguno recibe `SUPABASE_URL` /
`SUPABASE_PUBLISHABLE_KEY` si no se pasan explícitamente.

🟢  Build Android release correcto (usa el script, no se puede olvidar el dart-define):

powershell -File scripts/build_android_release.ps1 -Flavor prod
powershell -File scripts/build_android_release.ps1 -Flavor beta

Equivalente manual, por si no se usa el script:

flutter build apk --release --flavor prod --dart-define-from-file=.vscode/supabase.env.json
flutter build apk --release --flavor beta --dart-define-from-file=.vscode/supabase.env.json

flutter run -d windows

🔴  PARA COMPILAR = flutter build windows --release --dart-define-from-file=.vscode/supabase.env.json