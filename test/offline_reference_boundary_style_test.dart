import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/offline_reference_map_layer.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';

void main() {
  group('Buenos Aires administrative boundary style gate', () {
    bool decide({
      PmtilesDeliveryStatus status = PmtilesDeliveryStatus.available,
      bool visible = true,
      bool mapReady = true,
      bool hasBuenosAiresPolygons = true,
    }) {
      return shouldUseEnhancedBuenosAiresBoundaryStyle(
        deliveryStatus: status,
        soilPolygonsVisible: visible,
        mapReady: mapReady,
        hasVisibleBuenosAiresPolygons: hasBuenosAiresPolygons,
      );
    }

    test('enhances only when available and Buenos Aires polygons render', () {
      expect(decide(), isTrue);
    });

    test('keeps the original style while not installed or downloading', () {
      expect(decide(status: PmtilesDeliveryStatus.notInstalled), isFalse);
      expect(decide(status: PmtilesDeliveryStatus.downloading), isFalse);
    });

    test('keeps the original style when delivery fails', () {
      expect(decide(status: PmtilesDeliveryStatus.error), isFalse);
    });

    test('keeps the original style when the visibility toggle is off', () {
      expect(decide(visible: false), isFalse);
    });

    test(
      'keeps the original style until map and polygon rendering are ready',
      () {
        expect(decide(mapReady: false), isFalse);
        expect(decide(hasBuenosAiresPolygons: false), isFalse);
      },
    );
  });

  group('Buenos Aires enhanced boundary zoom fade', () {
    test('uses the requested opacity at the profile zooms', () {
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(10), 1);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(11), 0.75);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(12), 0.5);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(13), 0.3);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(14), 0.15);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(15), 0.08);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(16), 0.045);
    });

    test('interpolates smoothly between zoom levels in both directions', () {
      expect(
        enhancedBuenosAiresBoundaryOpacityAtZoom(10.5),
        closeTo(0.875, 1e-12),
      );
      expect(
        enhancedBuenosAiresBoundaryOpacityAtZoom(11.5),
        closeTo(0.625, 1e-12),
      );
      expect(
        enhancedBuenosAiresBoundaryOpacityAtZoom(13.5),
        closeTo(0.225, 1e-12),
      );
      expect(
        enhancedBuenosAiresBoundaryOpacityAtZoom(15.5),
        closeTo(0.0625, 1e-12),
      );
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(9), 1);
      expect(enhancedBuenosAiresBoundaryOpacityAtZoom(18), 0.045);
    });
  });

  group('geographic label contrast over soil polygons', () {
    test('preserves the existing palette when polygons are not active', () {
      expect(
        geographicLabelTextColor(enhancedForSoilPolygons: false),
        const Color(0xFF29312C),
      );
      expect(
        jurisdictionLabelTextColor(enhancedForSoilPolygons: false),
        const Color(0xFF4B5148),
      );
      expect(
        geographicLabelHaloColor(enhancedForSoilPolygons: false),
        const Color(0xFFFCFCFA),
      );
      expect(
        localityLabelHaloWidth(enhancedForSoilPolygons: false, isPrimary: true),
        5,
      );
      expect(
        localityLabelHaloWidth(
          enhancedForSoilPolygons: false,
          isPrimary: false,
        ),
        4.5,
      );
      expect(jurisdictionLabelHaloWidth(enhancedForSoilPolygons: false), 3.4);
    });

    test('uses the enhanced charcoal and warm continuous halo when active', () {
      expect(
        geographicLabelTextColor(enhancedForSoilPolygons: true),
        const Color(0xFF20271F),
      );
      expect(
        jurisdictionLabelTextColor(enhancedForSoilPolygons: true),
        const Color(0xFF20271F),
      );
      expect(
        geographicLabelHaloColor(enhancedForSoilPolygons: true),
        const Color(0xFFF7F7F1),
      );
      expect(
        localityLabelHaloWidth(enhancedForSoilPolygons: true, isPrimary: true),
        3.8,
      );
      expect(
        localityLabelHaloWidth(enhancedForSoilPolygons: true, isPrimary: false),
        3.8,
      );
      expect(jurisdictionLabelHaloWidth(enhancedForSoilPolygons: true), 3.8);
    });
  });
}
