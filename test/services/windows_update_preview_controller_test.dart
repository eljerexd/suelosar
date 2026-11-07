import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_update_indicator_controller.dart';

void main() {
  test(
    'preview state is volatile and cannot run a real update check',
    () async {
      final controller =
          WindowsUpdateIndicatorController.forDevelopmentPreview();
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.isDevelopmentPreview, isTrue);
      expect(controller.state, WindowsUpdateIndicatorState.updateAvailable);
      expect(controller.latestAvailableRelease?.version.toString(), '1.8.0');
      expect(controller.lastStableRelease?.version.toString(), '1.8.0');
      expect(await controller.checkManually(), isNull);
      expect(controller.state, WindowsUpdateIndicatorState.updateAvailable);
    },
  );
}
