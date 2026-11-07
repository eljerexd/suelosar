import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:suelosar/gis/engine/flutter_map_engine.dart';
import 'package:suelosar/gis/engine/soil_map_engine.dart';

void main() {
  testWidgets('wheel zoom above an overlay stays anchored to the cursor', (
    tester,
  ) async {
    final engine = FlutterMapEngine();
    addTearDown(engine.dispose);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: engine.buildMapSurface(
            initialCenter: const LatLng(-34.6, -58.4),
            initialZoom: 8,
            minZoom: 3,
            maxZoom: 18,
            backgroundColor: Colors.white,
            gesturesEnabled: true,
            annotationGesturesEnabled: false,
            onReady: () {},
            onPositionChanged: (_, {required hasGesture}) {},
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (resolved) {
                          if (resolved is PointerScrollEvent) {
                            engine.zoomAtScreenPoint(
                              resolved.localPosition,
                              resolved.scrollDelta.dy,
                            );
                          }
                        },
                      );
                    }
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = Offset(600, 180);
    final pointBefore = engine.screenOffsetToLatLng(anchor)!;
    final zoomBefore = engine.camera.zoom;
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        timeStamp: Duration.zero,
        device: 17,
        position: anchor,
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pump();

    expect(engine.camera.zoom, closeTo(zoomBefore + 0.6, 1e-6));
    final pointAfter = engine.screenOffsetToLatLng(anchor)!;
    expect(pointAfter.latitude, closeTo(pointBefore.latitude, 1e-5));
    expect(pointAfter.longitude, closeTo(pointBefore.longitude, 1e-5));
  });

  group('SoilMapVisibleBounds.fromCorners', () {
    test('returns the enclosing geographic bounds', () {
      final bounds = SoilMapVisibleBounds.fromCorners([
        LatLng(-35.2, -64.1),
        LatLng(-34.8, -62.9),
        LatLng(-36.0, -63.5),
        LatLng(-35.5, -62.2),
      ]);

      expect(bounds, isNotNull);
      expect(bounds!.west, -64.1);
      expect(bounds.south, -36.0);
      expect(bounds.east, -62.2);
      expect(bounds.north, -34.8);
    });

    test('returns null for empty or non-finite projected points', () {
      expect(SoilMapVisibleBounds.fromCorners(const []), isNull);
      expect(
        SoilMapVisibleBounds.fromCorners([
          const LatLng(double.nan, 0),
          const LatLng(1, 1),
        ]),
        isNull,
      );
    });
  });
}
