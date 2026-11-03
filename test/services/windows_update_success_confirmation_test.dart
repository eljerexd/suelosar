import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_update_success_confirmation.dart';

void main() {
  late Directory localAppData;

  setUp(() async {
    localAppData = await Directory.systemTemp.createTemp(
      'suelosar-update-success-',
    );
  });

  tearDown(() async {
    if (await localAppData.exists()) await localAppData.delete(recursive: true);
  });

  test('accepts only the helper success outcome with a valid token', () {
    expect(
      WindowsUpdateSuccessConfirmation.fromArguments([
        '--suelosar-update-result=installed',
        '--suelosar-update-version=1.7.0',
        '--suelosar-update-confirmation=${'a' * 32}',
      ], localAppDataPath: localAppData.path),
      isNotNull,
    );
  });

  test('failed and cancelled installations cannot create a success prompt', () {
    for (final outcome in ['cancelled', 'recovered', 'failed']) {
      expect(
        WindowsUpdateSuccessConfirmation.fromArguments([
          '--suelosar-update-result=$outcome',
          '--suelosar-update-version=1.7.0',
          '--suelosar-update-confirmation=${'a' * 32}',
        ], localAppDataPath: localAppData.path),
        isNull,
      );
    }
  });

  test(
    'restart without the helper confirmation does not report success',
    () async {
      final confirmation = _confirmation(localAppData.path);
      final result = await confirmation.consume(
        installedVersionReader: () async => '1.7.0',
        timeout: Duration.zero,
      );
      expect(result, isNull);
    },
  );

  test(
    'consumes a valid marker once and returns the actual installed version',
    () async {
      final confirmation = _confirmation(localAppData.path);
      await _writeMarker(confirmation, 'version=1.7.0');

      final first = await confirmation.consume(
        installedVersionReader: () async => '1.7.0+20',
      );
      final second = await confirmation.consume(
        installedVersionReader: () async => '1.7.0+20',
        timeout: Duration.zero,
      );

      expect(first, '1.7.0+20');
      expect(second, isNull);
      expect(await confirmation.confirmationFile.exists(), isFalse);
    },
  );

  test('rejects and consumes a marker for a different version', () async {
    final confirmation = _confirmation(localAppData.path);
    await _writeMarker(confirmation, 'version=1.7.1');

    final result = await confirmation.consume(
      installedVersionReader: () async => '1.7.0',
    );

    expect(result, isNull);
    expect(await confirmation.confirmationFile.exists(), isFalse);
  });

  test(
    'rejects a different version actually reported by the restarted app',
    () async {
      final confirmation = _confirmation(localAppData.path);
      await _writeMarker(confirmation, 'version=1.7.0');

      final result = await confirmation.consume(
        installedVersionReader: () async => '1.6.0+10',
      );

      expect(result, isNull);
      expect(await confirmation.confirmationFile.exists(), isFalse);
    },
  );
}

WindowsUpdateSuccessConfirmation _confirmation(String localAppDataPath) =>
    WindowsUpdateSuccessConfirmation(
      token: '0123456789abcdef0123456789abcdef',
      expectedVersion: '1.7.0',
      localAppDataPath: localAppDataPath,
    );

Future<void> _writeMarker(
  WindowsUpdateSuccessConfirmation confirmation,
  String content,
) async {
  await confirmation.confirmationFile.parent.create(recursive: true);
  await confirmation.confirmationFile.writeAsString(content);
}
