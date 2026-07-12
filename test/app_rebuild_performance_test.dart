import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/app/suelos_ar_app.dart';
import 'package:suelosar/services/settings_service.dart';

void main() {
  testWidgets('unrelated settings do not rebuild the root MaterialApp', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.instance.initialize();
    addTearDown(() async {
      await SettingsService.instance.setReduceAnimations(false);
      await SettingsService.instance.setConfirmBeforeDeleting(true);
    });
    await tester.pumpWidget(const SuelosARApp());
    await tester.pumpAndSettle();

    var rootBuilderRebuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is AnimatedBuilder ||
          element.widget.runtimeType.toString() == 'ListenableBuilder') {
        rootBuilderRebuilds++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await SettingsService.instance.setConfirmBeforeDeleting(false);
    await tester.pump();

    debugPrint('ROOT_SETTINGS_BUILDER_REBUILDS $rootBuilderRebuilds');
    expect(rootBuilderRebuilds, 0);

    await SettingsService.instance.setReduceAnimations(true);
    await tester.pump();
    final mediaQueries = tester.widgetList<MediaQuery>(find.byType(MediaQuery));
    expect(mediaQueries.any((widget) => widget.data.disableAnimations), isTrue);
  });
}
