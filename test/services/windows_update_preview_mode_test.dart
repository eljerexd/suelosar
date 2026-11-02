import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_update_preview_mode.dart';

void main() {
  test('preview is disabled by default', () {
    expect(updatePreviewModeEnabled, isFalse);
  });

  test('preview is permitted only when explicitly requested in debug', () {
    expect(isUpdatePreviewAllowed(debugBuild: true, requested: true), isTrue);
    expect(isUpdatePreviewAllowed(debugBuild: true, requested: false), isFalse);
    expect(isUpdatePreviewAllowed(debugBuild: false, requested: true), isFalse);
    expect(
      isUpdatePreviewAllowed(debugBuild: false, requested: false),
      isFalse,
    );
  });
}
