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

flutter run -d windows

PARA COMPILAR = flutter build windows --release --dart-define-from-file=.vscode/supabase.env.json

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