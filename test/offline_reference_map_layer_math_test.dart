// Fase 8C perf fix: `_AgronomicReferencePainter._paintLineLayers` stopped
// calling `camera.latLngToScreenOffset` per vertex and instead repositions a
// Path pre-projected once at a fixed reference zoom, using canvas
// translate/rotate/scale. That substitution relies on Web Mercator
// (`Epsg3857`, this app's only CRS) projecting linearly with `2^zoom`, i.e.
// `project(latLng, zoom) == project(latLng, refZoom) * 2^(zoom - refZoom)`.
//
// The painter's internals are private, so this test can't call them
// directly. Instead it independently re-derives the same formula using only
// flutter_map's public `MapCamera`/`Epsg3857` API and checks it reproduces
// `camera.latLngToScreenOffset` — the exact identity the optimization
// depends on — across a spread of centers, zooms, sizes, and rotations.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _referenceZoom = 0.0;
const _crs = Epsg3857();

/// Mirrors the canvas transform in `_paintLineLayers`:
/// `translate(halfSize) -> rotate(rotationRad) -> scale(scale) ->
/// translate(-cachedCenter)`, applied to a point cached at [_referenceZoom].
Offset _reprojectFromCache(MapCamera camera, LatLng latLng) {
  final cachedPoint = _crs.latLngToOffset(latLng, _referenceZoom);
  final cachedCenter = camera.projectAtZoom(camera.center, _referenceZoom);
  final scale = camera.getZoomScale(camera.zoom, _referenceZoom);
  final halfSize = camera.nonRotatedSize.center(Offset.zero);

  var point = (cachedPoint - cachedCenter) * scale;
  if (camera.rotation != 0) {
    point = Offset(
      point.dx * math.cos(camera.rotationRad) -
          point.dy * math.sin(camera.rotationRad),
      point.dx * math.sin(camera.rotationRad) +
          point.dy * math.cos(camera.rotationRad),
    );
  }
  return point + halfSize;
}

void main() {
  final samplePoints = const [
    LatLng(-34.6037, -58.3816), // Buenos Aires city
    LatLng(-31.4201, -61.4919), // Rafaela, Santa Fe
    LatLng(-38.0, -63.0), // Central Argentina, far from both centers
    LatLng(0, 0),
    LatLng(-89.9, 179.9), // Near a projection edge case
  ];

  final cameras = [
    for (final center in const [
      LatLng(-34.6037, -58.3816),
      LatLng(-31.4201, -61.4919),
      LatLng(-10, 100),
    ])
      for (final zoom in const [0.0, 4.3, 7.0, 9.75, 13.0])
        for (final rotation in const [0.0, 37.5, -90.0])
          for (final size in const [
            Size(400, 800),
            Size(1220, 900),
          ])
            MapCamera(
              crs: _crs,
              center: center,
              zoom: zoom,
              rotation: rotation,
              nonRotatedSize: size,
            ),
  ];

  test(
    'cached-path reprojection matches camera.latLngToScreenOffset exactly '
    'across centers, zooms, rotations, and viewport sizes',
    () {
      for (final camera in cameras) {
        for (final point in samplePoints) {
          final expected = camera.latLngToScreenOffset(point);
          final actual = _reprojectFromCache(camera, point);

          expect(
            actual.dx,
            closeTo(expected.dx, 1e-6),
            reason:
                'dx mismatch for center=${camera.center} zoom=${camera.zoom} '
                'rotation=${camera.rotation} size=${camera.nonRotatedSize} '
                'point=$point',
          );
          expect(
            actual.dy,
            closeTo(expected.dy, 1e-6),
            reason:
                'dy mismatch for center=${camera.center} zoom=${camera.zoom} '
                'rotation=${camera.rotation} size=${camera.nonRotatedSize} '
                'point=$point',
          );
        }
      }
    },
  );
}
