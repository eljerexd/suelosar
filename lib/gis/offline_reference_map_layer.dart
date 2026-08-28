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

  static const double _maxGeometryZoom = 13;
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

            final content =
                basemap == null ||
                    !cameraIsUsable ||
                    (!foreground && camera.zoom >= _maxGeometryZoom)
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
         const Color(0xB0AEB4AC),
         strokeWidth: _provincialBoundaryStrokeWidth,
       ),
       _departmentBoundaryPaint = _linePaint(
         const Color(0x8FCFD3CC),
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
  static const double _provincialBoundaryStrokeWidth = 0.9;
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
      final labelOpacity = _labelOpacity(camera.zoom);
      _drawCityLabels(canvas, size, labelOpacity);
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
    _provincialBoundaryPaint.strokeWidth =
        _provincialBoundaryStrokeWidth * inverseScale;
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

    recordingCanvas.drawPath(
      basemap.provincialBoundariesPath,
      _provincialBoundaryPaint,
    );

    final departmentOpacity = _zoomOpacity(snappedZoom, 7.8, 9);
    if (departmentOpacity > 0) {
      recordingCanvas.drawPath(
        basemap.departmentBoundariesPath,
        _paintAtOpacity(_departmentBoundaryPaint, departmentOpacity),
      );
    }

    recordingCanvas.drawPath(basemap.majorRiversPath, _riverCasingPaint);
    recordingCanvas.drawPath(basemap.majorRiversPath, _riverPaint);
    recordingCanvas.drawPath(
      basemap.nationalRoadsPath,
      _nationalRoadCasingPaint,
    );
    recordingCanvas.drawPath(basemap.nationalRoadsPath, _nationalRoadPaint);

    final regionalRoadOpacity = _zoomOpacity(snappedZoom, 8.2, 9.5);
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

  void _drawCityLabels(Canvas canvas, Size size, double opacity) {
    final occupiedLabels = <Rect>[];
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

  double _labelOpacity(double zoom) {
    return (0.78 + (zoom - 5).clamp(0.0, 2.5) * 0.072).clamp(0.78, 0.96);
  }

  double _cityVisibility(_ReferenceCity city) {
    return city.isPrimary ? 1 : _zoomOpacity(camera.zoom, 7.7, 9.4);
  }

  static double _zoomOpacity(double zoom, double start, double end) {
    return ((zoom - start) / (end - start)).clamp(0.0, 1.0);
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
  /// value near this app's actual operating zoom range (`_maxGeometryZoom`
  /// caps it at 13) over an arbitrary one like 0, which needs a much larger
  /// `canvas.scale` factor at typical zoom levels.
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
