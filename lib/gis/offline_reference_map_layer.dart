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
  const OfflineReferenceMapLayer({this.foreground = false, super.key});

  final bool foreground;

  static final Future<_AgronomicReferenceBasemap> _basemap =
      _AgronomicReferenceBasemap.load();

  static const double _maxGeometryZoom = 13;
  static const Color _backgroundColor = Color(0xFFFAFAF8);

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final cameraIsUsable =
        _isFiniteLatLng(camera.center) &&
        _isFiniteNumber(camera.zoom) &&
        _isFiniteNumber(camera.rotation);

    return IgnorePointer(
      child: RepaintBoundary(
        child: FutureBuilder<_AgronomicReferenceBasemap>(
          future: _basemap,
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
         strokeWidth: 0.9,
       ),
       _departmentBoundaryPaint = _linePaint(
         const Color(0x8FCFD3CC),
         strokeWidth: 0.5,
       ),
       _riverCasingPaint = _linePaint(const Color(0xB8F7FBFC), strokeWidth: 3),
       _riverPaint = _linePaint(const Color(0xE26BA9CC), strokeWidth: 1.55),
       _nationalRoadCasingPaint = _linePaint(
         const Color(0xE8FFF9F5),
         strokeWidth: 3.4,
       ),
       _nationalRoadPaint = _linePaint(
         const Color(0xE5BD5738),
         strokeWidth: 1.65,
       ),
       _provincialRoadCasingPaint = _linePaint(
         const Color(0xD8FFF9F5),
         strokeWidth: 2.65,
       ),
       _provincialRoadPaint = _linePaint(
         const Color(0xD2D77A59),
         strokeWidth: 1.15,
       );

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
      _drawLines(
        canvas,
        basemap.provincialBoundaries,
        _provincialBoundaryPaint,
      );
      final departmentOpacity = _zoomOpacity(camera.zoom, 7.8, 9);
      if (departmentOpacity > 0) {
        _drawLines(
          canvas,
          basemap.departmentBoundaries,
          _paintAtOpacity(_departmentBoundaryPaint, departmentOpacity),
        );
      }
    } else {
      _drawLines(canvas, basemap.majorRivers, _riverCasingPaint);
      _drawLines(canvas, basemap.majorRivers, _riverPaint);
      _drawLines(canvas, basemap.nationalRoads, _nationalRoadCasingPaint);
      _drawLines(canvas, basemap.nationalRoads, _nationalRoadPaint);

      final regionalRoadOpacity = _zoomOpacity(camera.zoom, 8.2, 9.5);
      if (regionalRoadOpacity > 0) {
        _drawLines(
          canvas,
          basemap.provincialRoads,
          _paintAtOpacity(_provincialRoadCasingPaint, regionalRoadOpacity),
        );
        _drawLines(
          canvas,
          basemap.provincialRoads,
          _paintAtOpacity(_provincialRoadPaint, regionalRoadOpacity),
        );
      }

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

  void _drawLines(Canvas canvas, List<List<LatLng>> lines, Paint paint) {
    for (final line in lines) {
      final path = ui.Path();
      var started = false;

      for (final point in line) {
        final offset = camera.latLngToScreenOffset(point);
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

      if (started) {
        canvas.drawPath(path, paint);
      }
    }
  }

  void _drawCityLabels(Canvas canvas, Size size, double opacity) {
    final occupiedLabels = <Rect>[];
    final symbolPaint = Paint()
      ..color = const Color(0xFF303632).withValues(alpha: opacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (final city in basemap.majorCities) {
      final cityOpacity = opacity * _cityVisibility(city);
      if (cityOpacity <= 0) {
        continue;
      }
      final offset = camera.latLngToScreenOffset(city.position);
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
      final offset = camera.latLngToScreenOffset(city.position);
      if (!_isFiniteOffset(offset)) {
        continue;
      }
      if (offset.dx < -city.labelWidth ||
          offset.dx > size.width + city.labelWidth ||
          offset.dy < -18 ||
          offset.dy > size.height + 18) {
        continue;
      }

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
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: city.labelWidth);

      final labelOffset = Offset(
        offset.dx + 5,
        offset.dy - textPainter.height / 2,
      );
      final labelBounds = labelOffset & textPainter.size;
      if (occupiedLabels.any(
        (bounds) => bounds.inflate(3).overlaps(labelBounds),
      )) {
        continue;
      }
      occupiedLabels.add(labelBounds);

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
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: city.labelWidth);
      haloPainter.paint(canvas, labelOffset);
      textPainter.paint(canvas, labelOffset);
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
  const _AgronomicReferenceBasemap({
    required this.provincialBoundaries,
    required this.departmentBoundaries,
    required this.majorRivers,
    required this.nationalRoads,
    required this.provincialRoads,
    required this.majorCities,
  });

  final List<List<LatLng>> provincialBoundaries;
  final List<List<LatLng>> departmentBoundaries;
  final List<List<LatLng>> majorRivers;
  final List<List<LatLng>> nationalRoads;
  final List<List<LatLng>> provincialRoads;
  final List<_ReferenceCity> majorCities;

  static Future<_AgronomicReferenceBasemap> load() async {
    final rawJson = await rootBundle.loadString(
      AssetPaths.agronomicReferenceMap,
    );
    final json = jsonDecode(rawJson) as Map<String, dynamic>;
    final crs = json['crs'] as String?;

    if (crs != 'EPSG:4326') {
      throw StateError('The reference basemap must use EPSG:4326.');
    }

    final layers = Map<String, dynamic>.from(json['layers'] as Map);

    return _AgronomicReferenceBasemap(
      provincialBoundaries: _parseLines(layers['provincialBoundaries']),
      departmentBoundaries: _parseLines(layers['departmentBoundaries']),
      majorRivers: _parseLines(layers['majorRivers']),
      nationalRoads: _parseLines(layers['nationalRoads']),
      provincialRoads: _parseLines(layers['provincialRoads']),
      majorCities: _parseCities(layers['majorCities']),
    );
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
  const _ReferenceCity({
    required this.name,
    required this.position,
    required this.isPrimary,
  });

  final String name;
  final LatLng position;
  final bool isPrimary;
  int get priority => isPrimary ? 1 : 0;
  double get labelWidth => (name.length * 8.2).clamp(52.0, 160.0);

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
