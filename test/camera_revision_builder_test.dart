import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/camera_revision_builder.dart';

void main() {
  testWidgets('reprojects a geographic overlay on every camera revision', (
    tester,
  ) async {
    final cameraRevision = ValueNotifier<int>(0);
    addTearDown(cameraRevision.dispose);
    var projectedPosition = const Offset(120, 90);

    await tester.pumpWidget(
      CameraRevisionBuilder(
        cameraChanges: cameraRevision,
        builder: (context) => Stack(
          alignment: Alignment.topLeft,
          children: [
            Positioned(
              left: projectedPosition.dx,
              top: projectedPosition.dy,
              child: const SizedBox(key: ValueKey('saved-label'), width: 80),
            ),
          ],
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('saved-label'))).dx,
      120,
    );

    projectedPosition = const Offset(260, 130);
    cameraRevision.value++;
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('saved-label'))),
      const Offset(260, 130),
    );
  });
}
