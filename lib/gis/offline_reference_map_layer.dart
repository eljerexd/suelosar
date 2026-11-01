import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../constants/asset_paths.dart';

/// Offline agronomic reference basemap rendered behind the soil polygons.
///
/// The source asset is a compact EPSG:4326 dataset, so flutter_map projects it
/// with the same camera and CRS used by the soil polygon layer.
class OfflineReferenceMapLayer extends StatelessWidget {
  const OfflineReferenceMapLayer({
    this.foreground = false,
    this.assetPaths = const [AssetPaths.agronomicReferenceMap],
    super.key,
  });

  final bool foreground;

  /// Basemap JSON assets to render, merged into one basemap — Fase 6: a
  /// single map screen spanning several provinces' coverage renders all of
  /// their reference maps together this way, without a per-province
  /// widget. Defaults to just Buenos Aires' — existing call sites that
  /// don't pass this keep loading exactly what they always have. An empty
  /// list (a coverage with no reference map of its own yet) renders
  /// nothing rather than falling back to Buenos Aires'.
  final List<String> assetPaths;

  // Keyed by the joined asset-path list, so two different combinations of
  // sources (or a single asset alone, used elsewhere) each cache
  // independently — every individual asset is still only ever read from
  // disk once per distinct combination requested.
  static final Map<String, Future<_AgronomicReferenceBasemap>> _basemapCache =
      <String, Future<_AgronomicReferenceBasemap>>{};

  static Future<_AgronomicReferenceBasemap> _loadCached(
    List<String> assetPaths,
  ) {
    return _basemapCache.putIfAbsent(
      assetPaths.join('|'),
      () => _AgronomicReferenceBasemap.loadAll(assetPaths),
    );
  }

  static const Color _backgroundColor = Color(0xFFFAFAF8);

  @override
  Widget build(BuildContext context) {
    if (assetPaths.isEmpty) {
      return const SizedBox.expand();
    }

    final camera = MapCamera.of(context);
    final cameraIsUsable =
        _isFiniteLatLng(camera.center) &&
        _isFiniteNumber(camera.zoom) &&
        _isFiniteNumber(camera.rotation);

    return IgnorePointer(
      child: RepaintBoundary(
        child: FutureBuilder<_AgronomicReferenceBasemap>(
          future: _loadCached(assetPaths),
          builder: (context, snapshot) {
            final basemap = snapshot.data;

            // Parte 7B: no zoom-level cutoff here anymore — the layer keeps
            // existing all the way to the map's own real maxZoom (16 for
            // Córdoba). What used to be a hard "stop building the geometry
            // pass past zoom 13" is now each individual line type fading to
            // 0% opacity on its own curve (see `_linePictureForZoom`), so at
            // extreme zoom this still builds a `CustomPaint` — it just
            // records an empty (or near-empty) Picture, at negligible cost.
            final content = basemap == null || !cameraIsUsable
                ? const SizedBox.expand()
                : CustomPaint(
                    painter: _AgronomicReferencePainter(
                      basemap: basemap,
                      camera: camera,
                      foreground: foreground,
                    ),
                    size: Size.infinite,
                  );
            return foreground
                ? content
                : ColoredBox(color: _backgroundColor, child: content);
          },
        ),
      ),
    );
  }
}

class _AgronomicReferencePainter extends CustomPainter {
  _AgronomicReferencePainter({
    required this.basemap,
    required this.camera,
    required this.foreground,
  }) : _provincialBoundaryPaint = _linePaint(
         const Color(0xDD2B2B2B),
         strokeWidth: 1,
       ),
       // Fase 6 Parte 38: a plain dark-charcoal stroke (no halo — a white
       // casing read as too heavy a "GIS layer" look against the app's own
       // muted palette) drawn in `_paintProvincialBoundary`, not here. Not
       // green, deliberately: the soil-unit borders already use the app's
       // primary green (`_GisPolygonStyle.normalBorder`), so the two
       // boundary kinds never get confused for one another.
       _departmentBoundaryPaint = _linePaint(
         const Color(0xB2545A50),
         strokeWidth: _departmentBoundaryStrokeWidth,
       ),
       _riverCasingPaint = _linePaint(
         const Color(0xB8F7FBFC),
         strokeWidth: _riverCasingStrokeWidth,
       ),
       _riverPaint = _linePaint(
         const Color(0xE26BA9CC),
         strokeWidth: _riverStrokeWidth,
       ),
       _nationalRoadCasingPaint = _linePaint(
         const Color(0xE8FFF9F5),
         strokeWidth: _nationalRoadCasingStrokeWidth,
       ),
       _nationalRoadPaint = _linePaint(
         const Color(0xE5BD5738),
         strokeWidth: _nationalRoadStrokeWidth,
       ),
       _provincialRoadCasingPaint = _linePaint(
         const Color(0xD8FFF9F5),
         strokeWidth: _provincialRoadCasingStrokeWidth,
       ),
       _provincialRoadPaint = _linePaint(
         const Color(0xD2D77A59),
         strokeWidth: _provincialRoadStrokeWidth,
       );

  // Named so both the initial Paint construction and the per-frame
  // stroke-width rescale in `_paintLineLayers` (needed to counteract the
  // canvas scale used to reposition cached geometry) read the same values.
  static const double _departmentBoundaryStrokeWidth = 0.5;
  static const double _riverCasingStrokeWidth = 3;
  static const double _riverStrokeWidth = 1.55;
  static const double _nationalRoadCasingStrokeWidth = 3.4;
  static const double _nationalRoadStrokeWidth = 1.65;
  static const double _provincialRoadCasingStrokeWidth = 2.65;
  static const double _provincialRoadStrokeWidth = 1.15;

  final _AgronomicReferenceBasemap basemap;
  final MapCamera camera;
  final bool foreground;
  final Paint _provincialBoundaryPaint;
  final Paint _departmentBoundaryPaint;
  final Paint _riverCasingPaint;
  final Paint _riverPaint;
  final Paint _nationalRoadCasingPaint;
  final Paint _nationalRoadPaint;
  final Paint _provincialRoadCasingPaint;
  final Paint _provincialRoadPaint;

  @override
  void paint(Canvas canvas, Size size) {
    if (!foreground) {
      _paintLineLayers(canvas);
    } else {
      // Fase 6 Parte 38: painted above the soil polygons (this is the
      // `foreground` pass), unlike every other reference line, which stays
      // in the background pass below them — a province boundary needs to
      // stay legible across neighbouring provinces' polygon fills, not be
      // covered by them. Drawn before the labels so a city/department label
      // always wins if the two ever overlap.
      _paintProvincialBoundary(canvas);

      // Shared between both label passes so a department name and a city
      // name never overlap each other either — cities are drawn second, so
      // a named settlement always wins a collision against a jurisdiction
      // label, consistent with the reference layer staying subordinate to
      // the more specific, more useful annotation.
      final occupiedLabels = <Rect>[];
      _drawDepartmentLabels(
        canvas,
        size,
        _departmentOpacity(camera.zoom),
        occupiedLabels,
      );
      _drawCityLabels(canvas, size, _labelOpacity(camera.zoom), occupiedLabels);
    }
  }

  @override
  bool shouldRepaint(_AgronomicReferencePainter oldDelegate) {
    return oldDelegate.basemap != basemap ||
        oldDelegate.camera != camera ||
        oldDelegate.foreground != foreground;
  }

  // Fase 8C perf fix: line geometry is static (it only ever comes from the
  // basemap JSON assets). A first pass (see `_linePictureForZoom` below)
  // stopped re-projecting it from lat/lng on every frame, using cached
  // Paths repositioned per-camera with a translate+scale(+rotate) — Web
  // Mercator scales linearly with 2^zoom, so that's exact. Real on-device
  // profiling showed that alone wasn't enough: `Canvas.drawPath` against
  // those cached Paths still cost ~60-70ms/frame of PAINT during pan under
  // Impeller, next to nothing of it actual GPU work — recording is itself
  // expensive when a path has this many vertices, independent of whether
  // per-point reprojection happens. So the *entire* drawPath sequence below
  // is now itself recorded once per zoom level into a `ui.Picture`
  // (`_linePictureForZoom`) and just replayed here; only the pan-dependent
  // translate (`center` changes every frame; zoom doesn't during a pan)
  // still runs per frame.
  void _paintLineLayers(Canvas canvas) {
    final halfSize = camera.nonRotatedSize.center(Offset.zero);
    // Snapped to a fixed 1/1000-of-a-zoom-level grid (see
    // `_linePictureForZoom`) — confirmed on-device with a forced-always-hit
    // diagnostic build that `drawPicture` replay itself is cheap (PAINT
    // ~83ms -> ~5ms during pan) and that the real problem was the cache
    // key: `MapCamera.zoom` drifts frame to frame during a pan even though
    // the map's logical zoom level never changes, so an exact `==` (or even
    // a tolerance *comparison* reusing the nearest previous exact zoom)
    // missed almost every pan frame in practice. Snapping *both* this and
    // the cached Picture to the same grid value, and using that snapped
    // value for the scale below too, means a cache hit is always an exact
    // match — no stale-scale mismatch between what the Picture was recorded
    // at and what this frame positions it with. The grid is far finer than
    // a real pinch-zoom frame's per-frame zoom delta, so that still misses
    // and rebuilds correctly, and coarser than any visually perceptible
    // scale change (each step is a ~0.07% scale difference).
    final snappedZoom = _AgronomicReferenceBasemap.snapZoomForCache(
      camera.zoom,
    );
    final scale = camera.getZoomScale(
      snappedZoom,
      _AgronomicReferenceBasemap.geometryCacheZoom,
    );
    // The picture already has `canvas.scale(scale)` baked in (see
    // `_linePictureForZoom`), so the pan offset below must be scaled to
    // match the coordinate space the picture is replayed into.
    final cachedCenter = camera.projectAtZoom(
      camera.center,
      _AgronomicReferenceBasemap.geometryCacheZoom,
    );
    final picture = _linePictureForZoom(snappedZoom, scale);

    canvas.save();
    canvas.translate(halfSize.dx, halfSize.dy);
    if (camera.rotation != 0) {
      canvas.rotate(camera.rotationRad);
    }
    canvas.translate(-cachedCenter.dx * scale, -cachedCenter.dy * scale);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  /// Returns the cached line-layer [ui.Picture] for [snappedZoom] (see
  /// [_AgronomicReferenceBasemap.snapZoomForCache]), rebuilding it only when
  /// it differs from the last one painted (see the cache fields on
  /// [_AgronomicReferenceBasemap] for why this is safe to share across
  /// camera positions/rotations and bounded to one entry).
  ui.Picture _linePictureForZoom(double snappedZoom, double scale) {
    final cachedZoom = basemap._cachedLineZoom;
    if (cachedZoom == snappedZoom) {
      final cached = basemap._cachedLinePicture;
      if (cached != null) {
        return cached;
      }
    }

    final recorder = ui.PictureRecorder();
    final recordingCanvas = Canvas(recorder);
    recordingCanvas.scale(scale);

    // Stroke widths are authored in on-screen logical pixels; the canvas
    // scale above would otherwise scale them right along with the geometry,
    // so it's cancelled out here to keep the rendered thickness unchanged.
    final inverseScale = 1 / scale;
    _departmentBoundaryPaint.strokeWidth =
        _departmentBoundaryStrokeWidth * inverseScale;
    _riverCasingPaint.strokeWidth = _riverCasingStrokeWidth * inverseScale;
    _riverPaint.strokeWidth = _riverStrokeWidth * inverseScale;
    _nationalRoadCasingPaint.strokeWidth =
        _nationalRoadCasingStrokeWidth * inverseScale;
    _nationalRoadPaint.strokeWidth = _nationalRoadStrokeWidth * inverseScale;
    _provincialRoadCasingPaint.strokeWidth =
        _provincialRoadCasingStrokeWidth * inverseScale;
    _provincialRoadPaint.strokeWidth =
        _provincialRoadStrokeWidth * inverseScale;

    final departmentOpacity = _departmentOpacity(snappedZoom);
    if (departmentOpacity > 0) {
      recordingCanvas.drawPath(
        basemap.departmentBoundariesPath,
        _paintAtOpacity(_departmentBoundaryPaint, departmentOpacity),
      );
    }

    final riverOpacity = _piecewiseOpacity(snappedZoom, _riverOpacityCurve);
    if (riverOpacity > 0) {
      recordingCanvas.drawPath(
        basemap.majorRiversPath,
        _paintAtOpacity(_riverCasingPaint, riverOpacity),
      );
      recordingCanvas.drawPath(
        basemap.majorRiversPath,
        _paintAtOpacity(_riverPaint, riverOpacity),
      );
    }

    final nationalRoadOpacity = _piecewiseOpacity(
      snappedZoom,
      _roadOpacityCurve,
    );
    if (nationalRoadOpacity > 0) {
      recordingCanvas.drawPath(
        basemap.nationalRoadsPath,
        _paintAtOpacity(_nationalRoadCasingPaint, nationalRoadOpacity),
      );
      recordingCanvas.drawPath(
        basemap.nationalRoadsPath,
        _paintAtOpacity(_nationalRoadPaint, nationalRoadOpacity),
      );
    }

    // Keeps its own existing appear-curve (8.2→9.5 — provincial roads stay
    // invisible until the map is zoomed in enough to be legible at all)
    // multiplied by the same never-reaches-0 fade-out roads share with
    // national roads — "caminos/rutas" is one design concept, both floor at
    // 40%. The appear-curve is already 1.0 well before zoom 10, so this
    // still floors at 0.4 rather than being dragged back down.
    final regionalRoadOpacity =
        _zoomOpacity(snappedZoom, 8.2, 9.5) *
        _piecewiseOpacity(snappedZoom, _roadOpacityCurve);
    if (regionalRoadOpacity > 0) {
      recordingCanvas.drawPath(
        basemap.provincialRoadsPath,
        _paintAtOpacity(_provincialRoadCasingPaint, regionalRoadOpacity),
      );
      recordingCanvas.drawPath(
        basemap.provincialRoadsPath,
        _paintAtOpacity(_provincialRoadPaint, regionalRoadOpacity),
      );
    }

    basemap._cachedLinePicture?.dispose();
    final picture = recorder.endRecording();
    basemap._cachedLineZoom = snappedZoom;
    basemap._cachedLinePicture = picture;
    return picture;
  }

  /// Fase 6 Parte 38: province boundary, painted in the `foreground` pass
  /// (above the soil polygons) instead of bundled into [_linePictureForZoom]
  /// with the rest of the reference lines — same source geometry
  /// (`basemap.provincialBoundariesPath`, loaded once from each province's
  /// `ProvinceConfig.referenceMapAsset`, see `_ProvinceBoundaryLoader` for
  /// the equivalent reader the on-demand-download boundary highlight uses).
  /// Painted directly every frame rather than through the `ui.Picture`
  /// cache [_linePictureForZoom] uses — see Parte 43's note below on why.
  void _paintProvincialBoundary(Canvas canvas) {
    final snappedZoom = _AgronomicReferenceBasemap.snapZoomForCache(
      camera.zoom,
    );
    final opacity = _piecewiseOpacity(
      snappedZoom,
      _provincialBoundaryOpacityCurve,
    );
    if (opacity <= 0) return;

    final halfSize = camera.nonRotatedSize.center(Offset.zero);
    final scale = camera.getZoomScale(
      snappedZoom,
      _AgronomicReferenceBasemap.geometryCacheZoom,
    );
    final cachedCenter = camera.projectAtZoom(
      camera.center,
      _AgronomicReferenceBasemap.geometryCacheZoom,
    );
    final inverseScale = 1 / scale;
    final strokeWidth = _piecewiseOpacity(
      snappedZoom,
      _provincialBoundaryWidthCurve,
    );

    // Fase 6 Parte 43: drawn directly every frame instead of through a
    // cached `ui.Picture` (Parte 38's original approach) — recording this
    // specific path (a merged, 50-subpath path spanning all three
    // provinces, stroked at a large scale-up factor at low zoom) into a
    // `ui.Picture` and replaying it reproducibly dropped one long straight
    // stretch of Córdoba's boundary (confirmed on-device: the segment is
    // present and correctly positioned in the path data — `drawPath` called
    // directly renders it — but it silently failed to render whenever it
    // went through `PictureRecorder`/`Canvas.drawPicture`). The background
    // reference lines keep their own Picture cache (`_linePictureForZoom`)
    // since that one isn't affected — only this layer's cache is removed.
    canvas.save();
    canvas.translate(halfSize.dx, halfSize.dy);
    if (camera.rotation != 0) {
      canvas.rotate(camera.rotationRad);
    }
    canvas.translate(-cachedCenter.dx * scale, -cachedCenter.dy * scale);
    canvas.scale(scale);
    canvas.drawPath(
      basemap.provincialBoundariesPath,
      _paintAtOpacity(
        _provincialBoundaryPaint..strokeWidth = strokeWidth * inverseScale,
        opacity,
      ),
    );
    canvas.restore();
  }

  void _drawCityLabels(
    Canvas canvas,
    Size size,
    double opacity,
    List<Rect> occupiedLabels,
  ) {
    final symbolPaint = Paint()
      ..color = const Color(0xFF303632).withValues(alpha: opacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Same fix as the line layers: `camera.latLngToScreenOffset` internally
    // re-projects `camera.center` on every call, so it's hoisted once here
    // instead of once per city per loop (this widget draws two passes:
    // circles, then labels).
    final mapCenter = camera.projectAtZoom(camera.center);
    final nonRotatedPixelOrigin =
        mapCenter - camera.nonRotatedSize.center(Offset.zero);
    Offset project(LatLng latLng) {
      var point = camera.projectAtZoom(latLng);
      if (camera.rotation != 0) {
        point = camera.rotatePoint(mapCenter, point, counterRotation: false);
      }
      return point - nonRotatedPixelOrigin;
    }

    for (final city in basemap.majorCities) {
      final cityOpacity = opacity * _cityVisibility(city);
      if (cityOpacity <= 0) {
        continue;
      }
      final offset = project(city.position);
      if (!_isFiniteOffset(offset)) {
        continue;
      }
      if (offset.dx >= -4 &&
          offset.dx <= size.width + 4 &&
          offset.dy >= -4 &&
          offset.dy <= size.height + 4) {
        symbolPaint.color = const Color(
          0xFF303632,
        ).withValues(alpha: cityOpacity);
        canvas.drawCircle(offset, city.isPrimary ? 2.7 : 2.3, symbolPaint);
      }
    }

    for (final city in basemap.majorCities) {
      final cityOpacity = opacity * _cityVisibility(city);
      if (cityOpacity <= 0) {
        continue;
      }
      final offset = project(city.position);
      if (!_isFiniteOffset(offset)) {
        continue;
      }
      // Cheap reject before paying for TextPainter.layout() (Fase 8 perf
      // audit: this loop used to build+layout every city's label — up to
      // two TextPainters each — before checking whether it was anywhere
      // near the canvas, so panning/zooming with most of the 30 cities
      // off-screen still paid full text-layout cost for all of them every
      // frame). A label starts ~5px right of its point and is realistically
      // well under 260px wide, so anything past these generous margins
      // can't produce a visible label — margins are intentionally loose so
      // this never culls a label that would actually be drawn.
      if (offset.dx < -260 ||
          offset.dx > size.width + 20 ||
          offset.dy < -40 ||
          offset.dy > size.height + 40) {
        continue;
      }
      // Fase 8C perf fix: measuring on-device showed labels, not lines, were
      // the dominant PAINT cost. Caching the laid-out `TextPainter` (as a
      // first attempt) made no measurable difference — the expensive part
      // isn't `layout()`, it's the halo's *stroked* text render inside
      // `.paint()` itself (stroking glyph outlines), which still ran fresh
      // every frame even with a cached, already-laid-out TextPainter. So
      // instead the whole rendered label (halo + text, at a fixed local
      // origin) is recorded once into a `ui.Picture` and just replayed
      // (translated into place) on every later frame — same "record once,
      // reposition cheaply" idea as `_paintLineLayers`, applied to whichever
      // part of the pipeline is actually doing the expensive work. Rebuilt
      // only when `cityOpacity` changes (zoom-only, per `_labelOpacity`/
      // `_cityVisibility` — constant across a pure pan).
      if (city._cachedOpacity != cityOpacity ||
          city._cachedLabelPicture == null) {
        final style = TextStyle(
          color: const Color(0xFF29312C).withValues(alpha: cityOpacity),
          fontSize: city.isPrimary ? 16 : 14.5,
          fontWeight: city.isPrimary ? FontWeight.w700 : FontWeight.w600,
          height: 1.05,
        );
        final textPainter = TextPainter(
          text: TextSpan(text: city.name, style: style),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();

        final haloStyle = style.copyWith(
          foreground: Paint()
            ..color = const Color(
              0xFFFCFCFA,
            ).withValues(alpha: cityOpacity * 0.98)
            ..style = PaintingStyle.stroke
            ..strokeWidth = city.isPrimary ? 5 : 4.5
            ..strokeJoin = StrokeJoin.round,
        );
        final haloPainter = TextPainter(
          text: TextSpan(text: city.name, style: haloStyle),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();

        final recorder = ui.PictureRecorder();
        final recordingCanvas = Canvas(recorder);
        haloPainter.paint(recordingCanvas, Offset.zero);
        textPainter.paint(recordingCanvas, Offset.zero);

        city._cachedLabelPicture?.dispose();
        city._cachedLabelPicture = recorder.endRecording();
        city._cachedLabelSize = textPainter.size;
        city._cachedLabelHeight = textPainter.height;
        city._cachedOpacity = cityOpacity;
      }

      final labelSize = city._cachedLabelSize!;
      final labelOffset = Offset(
        offset.dx + 5,
        offset.dy - city._cachedLabelHeight! / 2,
      );
      final labelBounds = labelOffset & labelSize;
      if (!labelBounds.overlaps(Offset.zero & size)) {
        continue;
      }
      if (occupiedLabels.any(
        (bounds) => bounds.inflate(3).overlaps(labelBounds),
      )) {
        continue;
      }
      occupiedLabels.add(labelBounds);

      canvas.save();
      canvas.translate(labelOffset.dx, labelOffset.dy);
      canvas.drawPicture(city._cachedLabelPicture!);
      canvas.restore();
    }
  }

  /// Jurisdiction name labels (Parte 6) — deliberately quieter than
  /// [_drawCityLabels]: uppercase with letter-spacing (a standard
  /// cartographic convention for administrative areas, as opposed to point
  /// places), a dark-but-not-black neutral tone, and no marker glyph (a
  /// department is an area, not a point — there is nothing to mark). Centred
  /// on its own centroid rather than offset beside it, since there is no
  /// point symbol to sit next to.
  void _drawDepartmentLabels(
    Canvas canvas,
    Size size,
    double opacity,
    List<Rect> occupiedLabels,
  ) {
    if (opacity <= 0 || basemap.departmentLabels.isEmpty) return;

    final mapCenter = camera.projectAtZoom(camera.center);
    final nonRotatedPixelOrigin =
        mapCenter - camera.nonRotatedSize.center(Offset.zero);
    Offset project(LatLng latLng) {
      var point = camera.projectAtZoom(latLng);
      if (camera.rotation != 0) {
        point = camera.rotatePoint(mapCenter, point, counterRotation: false);
      }
      return point - nonRotatedPixelOrigin;
    }

    for (final department in basemap.departmentLabels) {
      final offset = project(department.position);
      if (!_isFiniteOffset(offset)) continue;
      // Same cheap off-screen reject as `_drawCityLabels`, generous enough
      // to never cull a label that would actually end up visible.
      if (offset.dx < -140 ||
          offset.dx > size.width + 140 ||
          offset.dy < -20 ||
          offset.dy > size.height + 20) {
        continue;
      }

      if (department._cachedOpacity != opacity ||
          department._cachedLabelPicture == null) {
        final style = TextStyle(
          color: const Color(0xFF4B5148).withValues(alpha: opacity),
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          height: 1,
        );
        final label = department.name.toUpperCase();
        final textPainter = TextPainter(
          text: TextSpan(text: label, style: style),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();

        final haloStyle = style.copyWith(
          foreground: Paint()
            ..color = const Color(0xFFFCFCFA).withValues(alpha: opacity * 0.98)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.4
            ..strokeJoin = StrokeJoin.round,
        );
        final haloPainter = TextPainter(
          text: TextSpan(text: label, style: haloStyle),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();

        final recorder = ui.PictureRecorder();
        final recordingCanvas = Canvas(recorder);
        haloPainter.paint(recordingCanvas, Offset.zero);
        textPainter.paint(recordingCanvas, Offset.zero);

        department._cachedLabelPicture?.dispose();
        department._cachedLabelPicture = recorder.endRecording();
        department._cachedLabelSize = textPainter.size;
        department._cachedLabelHeight = textPainter.height;
        department._cachedOpacity = opacity;
      }

      final labelSize = department._cachedLabelSize!;
      final labelOffset = Offset(
        offset.dx - labelSize.width / 2,
        offset.dy - department._cachedLabelHeight! / 2,
      );
      final labelBounds = labelOffset & labelSize;
      if (!labelBounds.overlaps(Offset.zero & size)) continue;
      if (occupiedLabels.any(
        (bounds) => bounds.inflate(3).overlaps(labelBounds),
      )) {
        continue;
      }
      occupiedLabels.add(labelBounds);

      canvas.save();
      canvas.translate(labelOffset.dx, labelOffset.dy);
      canvas.drawPicture(department._cachedLabelPicture!);
      canvas.restore();
    }
  }

  double _labelOpacity(double zoom) {
    return (0.78 + (zoom - 5).clamp(0.0, 2.5) * 0.072).clamp(0.78, 0.96);
  }

  double _cityVisibility(_ReferenceCity city) {
    return city.isPrimary ? 1 : _zoomOpacity(camera.zoom, 7.7, 9.4);
  }

  /// Jurisdiction boundary lines AND their name labels (Parte 6) share this
  /// exact curve, so the labels never linger after their lines have already
  /// faded — a linear ramp from fully visible at zoom 7-8 down to invisible
  /// at zoom 12, well before the soil layer's own detail (map-unit symbols
  /// start at zoom 10) becomes the protagonist:
  /// zoom <=8 -> 100%, 9 -> 75%, 10 -> 50%, 11 -> 25%, >=12 -> 0%.
  static double _departmentOpacity(double zoom) {
    return 1 - _zoomOpacity(zoom, 8, 12);
  }

  static double _zoomOpacity(double zoom, double start, double end) {
    return ((zoom - start) / (end - start)).clamp(0.0, 1.0);
  }

  /// Fase 6 Parte 38: unlike the other reference lines below, this one has
  /// to be gone well before the soil layer's own detail (map-unit symbols
  /// from zoom 10, SIMBC labels competing for the same screen space) takes
  /// over — it's now painted above the polygons, so lingering into that
  /// range would mean a province-edge halo cutting across unit labels.
  /// Clearly visible at the province-overview zooms (<=7, where it's the
  /// whole point — telling neighbouring provinces' polygons apart), then
  /// eases out through the mid zooms and is fully gone by 13. Control
  /// points, not a single linear ramp — see [_piecewiseOpacity].
  static const List<(double, double)> _provincialBoundaryOpacityCurve = [
    (7, 1.0),
    (9, 0.85),
    (10, 0.6),
    (11, 0.35),
    (12, 0.15),
    (13, 0.0),
  ];

  /// Companion to [_provincialBoundaryOpacityCurve] — logical-pixel stroke
  /// width, authored in on-screen px (see the `inverseScale` cancellation in
  /// [_paintProvincialBoundary]) so it shrinks as the province overview
  /// gives way to the soil layer's own detail, same reasoning as the
  /// opacity fade above.
  static const List<(double, double)> _provincialBoundaryWidthCurve = [
    (7, 2.2),
    (9, 1.7),
    (10, 1.2),
    (11, 0.8),
    (12, 0.4),
    (13, 0.0),
  ];

  /// A touch faster than the provincial boundary — rivers are the least
  /// essential wayfinding element of the three once the soil layer is doing
  /// most of the work, so they're fully gone by zoom 15 rather than 16.
  static const List<(double, double)> _riverOpacityCurve = [
    (10, 1.0),
    (11, 0.75),
    (12, 0.5),
    (13, 0.3),
    (14, 0.15),
    (15, 0.0),
  ];

  /// Design adjustment: roads never go all the way to 0% like the other
  /// reference elements do — the map's own soil-navigation actions (search,
  /// GPS) keep referring to roads by name, so a road stays a usable anchor
  /// even at the soil layer's own maximum detail. Floors at 40%, never
  /// fully invisible. Shared by both national and provincial/regional
  /// roads — "caminos/rutas" is one concept here, not two.
  static const List<(double, double)> _roadOpacityCurve = [
    (10, 1.0),
    (11, 0.9),
    (12, 0.8),
    (13, 0.7),
    (14, 0.6),
    (15, 0.5),
    (16, 0.4),
  ];

  /// Linear interpolation through [points] (sorted by zoom, ascending).
  /// Below the first point or above the last, the curve holds flat at that
  /// point's opacity — it does not extrapolate past the data.
  static double _piecewiseOpacity(double zoom, List<(double, double)> points) {
    if (zoom <= points.first.$1) return points.first.$2;
    if (zoom >= points.last.$1) return points.last.$2;
    for (var i = 0; i < points.length - 1; i++) {
      final (z0, o0) = points[i];
      final (z1, o1) = points[i + 1];
      if (zoom <= z1) {
        return o0 + (o1 - o0) * (zoom - z0) / (z1 - z0);
      }
    }
    return points.last.$2; // Unreachable: the loop above always returns.
  }

  static Paint _paintAtOpacity(Paint source, double opacity) {
    return Paint()
      ..color = source.color.withValues(alpha: source.color.a * opacity)
      ..strokeWidth = source.strokeWidth
      ..strokeCap = source.strokeCap
      ..strokeJoin = source.strokeJoin
      ..style = source.style
      ..isAntiAlias = source.isAntiAlias;
  }

  static Paint _linePaint(Color color, {required double strokeWidth}) {
    return Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
  }
}

class _AgronomicReferenceBasemap {
  _AgronomicReferenceBasemap({
    required this.provincialBoundaries,
    required this.departmentBoundaries,
    required this.majorRivers,
    required this.nationalRoads,
    required this.provincialRoads,
    required this.majorCities,
    required this.departmentLabels,
    required this.provincialBoundariesPath,
    required this.departmentBoundariesPath,
    required this.majorRiversPath,
    required this.nationalRoadsPath,
    required this.provincialRoadsPath,
  });

  final List<List<LatLng>> provincialBoundaries;
  final List<List<LatLng>> departmentBoundaries;
  final List<List<LatLng>> majorRivers;
  final List<List<LatLng>> nationalRoads;
  final List<List<LatLng>> provincialRoads;
  final List<_ReferenceCity> majorCities;

  /// One label per department/jurisdiction (Parte 6) — empty for a basemap
  /// asset that predates this layer (Buenos Aires', Santa Fe's), which is
  /// why every reader of this list must tolerate empty, not assume Córdoba's
  /// 26.
  final List<_ReferenceDepartmentLabel> departmentLabels;

  /// Line geometry pre-projected once, at [geometryCacheZoom], into cached
  /// [ui.Path]s (Fase 8C perf fix) — see `_AgronomicReferencePainter
  ///._paintLineLayers` for how these are repositioned per frame without
  /// re-projecting every vertex.
  final ui.Path provincialBoundariesPath;
  final ui.Path departmentBoundariesPath;
  final ui.Path majorRiversPath;
  final ui.Path nationalRoadsPath;
  final ui.Path provincialRoadsPath;

  /// Reference zoom the cached paths above are projected at. Correctness
  /// doesn't depend on this value (Web Mercator scaling is exact for any
  /// zoom pair — see the painter's math test), but real on-device profiling
  /// (Fase 8C) measured a real, if modest, extra improvement from picking a
  /// value near this app's actual operating zoom range over an arbitrary
  /// one like 0, which needs a much larger `canvas.scale` factor at typical
  /// zoom levels.
  static const double geometryCacheZoom = 10;

  /// Rounds [zoom] to the nearest 1/1000-of-a-zoom-level grid point, so
  /// repeated calls during a pan (where the map's logical zoom never
  /// changes, but the exact `MapCamera.zoom` double drifts frame to frame)
  /// consistently produce the same value and hit [_cachedLineZoom]. See
  /// `_AgronomicReferencePainter._paintLineLayers`.
  static double snapZoomForCache(double zoom) {
    const grid = 1e-3;
    return (zoom / grid).round() * grid;
  }

  // Building the cache doesn't have a live MapCamera to read `crs` from
  // (loading happens once, independent of any particular map screen
  // instance), so this hardcodes this app's only CRS — flutter_map defaults
  // to it and nothing in this codebase overrides `MapOptions.crs`.
  static const Epsg3857 _geometryCacheCrs = Epsg3857();

  /// Fully-recorded line-layer [ui.Picture], for the single most recent zoom
  /// level painted — Fase 8C, escalation to "Option 2" after the Path cache
  /// above (record geometry once, reposition via canvas transforms) turned
  /// out not to be enough on its own: real on-device profiling showed
  /// `Canvas.drawPath` against those cached Paths still cost ~60-70ms/frame
  /// of PAINT under Impeller, regardless of the (now cheap) per-frame
  /// reprojection — recording a `Picture` once per zoom level and replaying
  /// it with `drawPicture` removes that remaining cost for the case that was
  /// actually measured as broken: a pure pan, where zoom never changes and
  /// this cache is a hit on every frame after the first. A pinch-zoom
  /// gesture changes `zoom` on nearly every frame, so it stays a cache miss
  /// there — same cost as before, not worse. Deliberately bounded to one
  /// entry (not a growing cache): the previous [ui.Picture] is disposed
  /// whenever a new zoom evicts it.
  double? _cachedLineZoom;
  ui.Picture? _cachedLinePicture;

  /// Loads every asset in [assetPaths] via [load] and concatenates their
  /// layers into one basemap — Fase 6: how a multi-coverage map screen
  /// renders several provinces' reference maps as if they were one. Cities
  /// are re-sorted by priority after merging, since concatenating two
  /// already-sorted lists isn't itself sorted.
  static Future<_AgronomicReferenceBasemap> loadAll(
    List<String> assetPaths,
  ) async {
    final basemaps = await Future.wait(assetPaths.map(load));
    if (basemaps.length == 1) return basemaps.single;

    final majorCities = [
      for (final basemap in basemaps) ...basemap.majorCities,
    ]..sort((first, second) => second.priority.compareTo(first.priority));
    final departmentLabels = [
      for (final basemap in basemaps) ...basemap.departmentLabels,
    ];

    return _AgronomicReferenceBasemap(
      provincialBoundaries: [
        for (final basemap in basemaps) ...basemap.provincialBoundaries,
      ],
      departmentBoundaries: [
        for (final basemap in basemaps) ...basemap.departmentBoundaries,
      ],
      majorRivers: [for (final basemap in basemaps) ...basemap.majorRivers],
      nationalRoads: [
        for (final basemap in basemaps) ...basemap.nationalRoads,
      ],
      provincialRoads: [
        for (final basemap in basemaps) ...basemap.provincialRoads,
      ],
      majorCities: majorCities,
      departmentLabels: departmentLabels,
      // Merged from each basemap's already-projected cache (`Path.addPath`
      // just copies path data) rather than rebuilt from lat/lng, since every
      // basemap shares the same `geometryCacheZoom` reference frame.
      provincialBoundariesPath: _mergePaths(
        basemaps.map((basemap) => basemap.provincialBoundariesPath),
      ),
      departmentBoundariesPath: _mergePaths(
        basemaps.map((basemap) => basemap.departmentBoundariesPath),
      ),
      majorRiversPath: _mergePaths(
        basemaps.map((basemap) => basemap.majorRiversPath),
      ),
      nationalRoadsPath: _mergePaths(
        basemaps.map((basemap) => basemap.nationalRoadsPath),
      ),
      provincialRoadsPath: _mergePaths(
        basemaps.map((basemap) => basemap.provincialRoadsPath),
      ),
    );
  }

  static ui.Path _mergePaths(Iterable<ui.Path> paths) {
    final merged = ui.Path();
    for (final path in paths) {
      merged.addPath(path, Offset.zero);
    }
    return merged;
  }

  static Future<_AgronomicReferenceBasemap> load(String assetPath) async {
    final rawJson = await rootBundle.loadString(assetPath);
    final json = jsonDecode(rawJson) as Map<String, dynamic>;
    final crs = json['crs'] as String?;

    if (crs != 'EPSG:4326') {
      throw StateError('The reference basemap must use EPSG:4326.');
    }

    final layers = Map<String, dynamic>.from(json['layers'] as Map);

    final provincialBoundaries = _parseLines(layers['provincialBoundaries']);
    final departmentBoundaries = _parseLines(layers['departmentBoundaries']);
    final majorRivers = _parseLines(layers['majorRivers']);
    final nationalRoads = _parseLines(layers['nationalRoads']);
    final provincialRoads = _parseLines(layers['provincialRoads']);

    return _AgronomicReferenceBasemap(
      provincialBoundaries: provincialBoundaries,
      departmentBoundaries: departmentBoundaries,
      majorRivers: majorRivers,
      nationalRoads: nationalRoads,
      provincialRoads: provincialRoads,
      majorCities: _parseCities(layers['majorCities']),
      departmentLabels: _parseDepartmentLabels(layers['departmentLabels']),
      provincialBoundariesPath: _buildPath(provincialBoundaries),
      departmentBoundariesPath: _buildPath(departmentBoundaries),
      majorRiversPath: _buildPath(majorRivers),
      nationalRoadsPath: _buildPath(nationalRoads),
      provincialRoadsPath: _buildPath(provincialRoads),
    );
  }

  /// Projects every point of every [lines] once, at [geometryCacheZoom],
  /// into a single merged [ui.Path] (each line as its own subpath, so
  /// stroking still treats them independently — identical to how the old
  /// per-frame code drew one `Path` per line with the same `Paint`).
  static ui.Path _buildPath(List<List<LatLng>> lines) {
    final path = ui.Path();
    for (final line in lines) {
      var started = false;
      for (final point in line) {
        final offset = _geometryCacheCrs.latLngToOffset(
          point,
          geometryCacheZoom,
        );
        if (!_isFiniteOffset(offset)) {
          started = false;
          continue;
        }
        if (started) {
          path.lineTo(offset.dx, offset.dy);
        } else {
          path.moveTo(offset.dx, offset.dy);
          started = true;
        }
      }
    }
    return path;
  }

  static List<List<LatLng>> _parseLines(Object? rawLines) {
    final lines = rawLines as List<dynamic>? ?? const <dynamic>[];

    return [
      for (final rawLine in lines)
        [
          for (final rawPoint in rawLine as List<dynamic>)
            ?_parsePoint(rawPoint as List<dynamic>),
        ],
    ];
  }

  static List<_ReferenceCity> _parseCities(Object? rawCities) {
    final cities = rawCities as List<dynamic>? ?? const <dynamic>[];

    final parsedCities = [
      for (final rawCity in cities)
        ?_ReferenceCity.fromJson(Map<String, dynamic>.from(rawCity as Map)),
    ];
    parsedCities.sort(
      (first, second) => second.priority.compareTo(first.priority),
    );
    return parsedCities;
  }

  static List<_ReferenceDepartmentLabel> _parseDepartmentLabels(
    Object? rawLabels,
  ) {
    final labels = rawLabels as List<dynamic>? ?? const <dynamic>[];
    return [
      for (final rawLabel in labels)
        ?_ReferenceDepartmentLabel.fromJson(
          Map<String, dynamic>.from(rawLabel as Map),
        ),
    ];
  }

  static LatLng? _parsePoint(List<dynamic> rawPoint) {
    final longitude = (rawPoint[0] as num).toDouble();
    final latitude = (rawPoint[1] as num).toDouble();

    return _safeLatLng(latitude, longitude);
  }
}

class _ReferenceCity {
  _ReferenceCity({
    required this.name,
    required this.position,
    required this.isPrimary,
  });

  final String name;
  final LatLng position;
  final bool isPrimary;
  int get priority => isPrimary ? 1 : 0;

  // Fase 8C perf fix: a label's rendered look (its shaped+stroked halo and
  // text) depends only on its name/style and `cityOpacity` (baked into the
  // style's color) — never on screen position. `cityOpacity` itself depends
  // only on `camera.zoom` (see `_labelOpacity`/`_cityVisibility`), so it's
  // identical on every frame of a pure pan. The fully rendered label is
  // cached here as a `ui.Picture`, keyed by the opacity it was built for —
  // see `_AgronomicReferencePainter._drawCityLabels`.
  double? _cachedOpacity;
  ui.Picture? _cachedLabelPicture;
  Size? _cachedLabelSize;
  double? _cachedLabelHeight;

  static _ReferenceCity? fromJson(Map<String, dynamic> json) {
    final position = _safeLatLng(
      (json['lat'] as num).toDouble(),
      (json['lon'] as num).toDouble(),
    );
    if (position == null) return null;
    return _ReferenceCity(
      name: json['name'] as String,
      position: position,
      isPrimary: json['importance'] == 'primary',
    );
  }
}

/// One department/jurisdiction name label (Parte 6), at the polygon
/// centroid `tool/build_reference_map.dart` computed. Caching fields mirror
/// [_ReferenceCity]'s own — same "record the rendered label once, replay it"
/// reasoning (Fase 8C), since the fade curve holds the opacity constant
/// across a pure pan just like a city's does.
class _ReferenceDepartmentLabel {
  _ReferenceDepartmentLabel({required this.name, required this.position});

  final String name;
  final LatLng position;

  double? _cachedOpacity;
  ui.Picture? _cachedLabelPicture;
  Size? _cachedLabelSize;
  double? _cachedLabelHeight;

  static _ReferenceDepartmentLabel? fromJson(Map<String, dynamic> json) {
    final position = _safeLatLng(
      (json['lat'] as num).toDouble(),
      (json['lon'] as num).toDouble(),
    );
    if (position == null) return null;
    return _ReferenceDepartmentLabel(
      name: json['name'] as String,
      position: position,
    );
  }
}

LatLng? _safeLatLng(double latitude, double longitude) {
  if (!_isFiniteCoordinateValues(latitude, longitude)) {
    return null;
  }
  return LatLng(latitude, longitude);
}

bool _isFiniteLatLng(LatLng point) {
  return _isFiniteCoordinateValues(point.latitude, point.longitude);
}

bool _isFiniteCoordinateValues(double latitude, double longitude) {
  return _isFiniteNumber(latitude) && _isFiniteNumber(longitude);
}

bool _isFiniteOffset(Offset offset) {
  return _isFiniteNumber(offset.dx) && _isFiniteNumber(offset.dy);
}

bool _isFiniteNumber(double value) {
  return value.isFinite && !value.isNaN;
}
