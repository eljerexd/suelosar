import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/desktop_window_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');

  testWidgets('fullscreen preserves a native maximized window', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var fullScreen = false;
    var maximized = true;
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return switch (call.method) {
        'ensureInitialized' => null,
        'isFullScreen' => fullScreen,
        'isMaximized' => maximized,
        'unmaximize' => maximized = false,
        'maximize' => maximized = true,
        'setFullScreen' =>
          fullScreen =
              (call.arguments as Map<Object?, Object?>)['isFullScreen']!
                  as bool,
        _ => null,
      };
    });
    final service = WindowManagerDesktopWindowService();
    try {
      await service.toggleFullScreen();
      expect(fullScreen, isTrue);
      expect(maximized, isFalse);
      expect(
        calls,
        containsAllInOrder(['isMaximized', 'unmaximize', 'setFullScreen']),
      );

      calls.clear();
      await service.toggleFullScreen();
      expect(fullScreen, isFalse);
      expect(maximized, isTrue);
      expect(
        calls,
        containsAllInOrder(['setFullScreen', 'isMaximized', 'maximize']),
      );
    } finally {
      service.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
