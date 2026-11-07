import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/app/app_theme.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profiles fast scrolling through the complete soil-map catalog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const SoilMapsScreen()),
    );
    await _waitForCatalog(tester);
    // Keep the profile isolate available long enough for flutter drive to
    // attach before starting the benchmark action.
    await Future<void>.delayed(const Duration(seconds: 10));

    final catalog = find.byType(CustomScrollView);
    expect(catalog, findsOneWidget);
    final scrollable = find.descendant(
      of: catalog,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));

    final timings = <ui.FrameTiming>[];
    await Future<void>.delayed(const Duration(seconds: 2));
    binding.addTimingsCallback(timings.addAll);

    var flingCount = 0;
    Future<void> scrollToEdge({required bool bottom}) async {
      while (flingCount < 300) {
        final atEdge = bottom
            ? position.pixels >= position.maxScrollExtent - 1
            : position.pixels <= 1;
        if (atEdge) return;

        final previousOffset = position.pixels;
        await tester.fling(catalog, Offset(0, bottom ? -700 : 700), 2400);
        await tester.pumpAndSettle();
        flingCount++;
        expect(position.pixels, isNot(previousOffset));
      }
      fail('The catalog did not reach its scroll boundary.');
    }

    await scrollToEdge(bottom: true);
    final maxScrollExtent = position.maxScrollExtent;
    await scrollToEdge(bottom: false);
    await Future<void>.delayed(const Duration(seconds: 2));
    binding.removeTimingsCallback(timings.addAll);

    expect(position.pixels, lessThanOrEqualTo(1));
    expect(timings, isNotEmpty);

    final frameSpanMs = timings
        .map((timing) => timing.totalSpan.inMicroseconds / 1000)
        .toList(growable: false);
    final buildMs = timings
        .map((timing) => timing.buildDuration.inMicroseconds / 1000)
        .toList(growable: false);
    final rasterMs = timings
        .map((timing) => timing.rasterDuration.inMicroseconds / 1000)
        .toList(growable: false);
    final result = <String, Object>{
      'device': 'emulator-5554 Android API 37 x86_64 1280x2856 @480dpi',
      'catalog_scroll_extent_logical_px': maxScrollExtent,
      'flings_for_full_down_and_up_traversal': flingCount,
      'frame_count': timings.length,
      'frame_total_span_median_ms': _percentile(frameSpanMs, 0.5),
      'frame_total_span_p95_ms': _percentile(frameSpanMs, 0.95),
      'frame_build_median_ms': _percentile(buildMs, 0.5),
      'frame_build_p95_ms': _percentile(buildMs, 0.95),
      'frame_raster_median_ms': _percentile(rasterMs, 0.5),
      'frame_raster_p95_ms': _percentile(rasterMs, 0.95),
      'frames_over_16_67ms': frameSpanMs.where((ms) => ms > 16.67).length,
    };
    debugPrint('SOIL_MAP_SCROLL_PROFILE ${jsonEncode(result)}');
    binding.reportData = <String, dynamic>{'soil_map_scroll': result};
  });
}

Future<void> _waitForCatalog(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.text('Todas las cartas').evaluate().isNotEmpty) return;
  }
  fail('The soil-map catalog did not finish loading.');
}

double _percentile(List<double> values, double fraction) {
  final sorted = values.toList()..sort();
  final rank = (fraction * (sorted.length - 1)).round();
  return double.parse(sorted[rank].toStringAsFixed(3));
}
