import 'dart:async';
import 'dart:io';

import 'windows_update_models.dart';

class WindowsUpdateSuccessConfirmation {
  WindowsUpdateSuccessConfirmation({
    required this.token,
    required this.expectedVersion,
    required this.localAppDataPath,
  });

  static final RegExp _tokenPattern = RegExp(r'^[a-fA-F0-9]{32}$');

  final String token;
  final String expectedVersion;
  final String localAppDataPath;

  static WindowsUpdateSuccessConfirmation? fromArguments(
    List<String> args, {
    String? localAppDataPath,
  }) {
    String? argument(String prefix) {
      for (final value in args) {
        if (value.startsWith(prefix)) return value.substring(prefix.length);
      }
      return null;
    }

    final outcome = argument('--suelosar-update-result=');
    final token = argument('--suelosar-update-confirmation=');
    final expectedVersion = argument('--suelosar-update-version=');
    final parsedExpected = expectedVersion == null
        ? null
        : UpdateVersion.tryParse(expectedVersion);
    final root = localAppDataPath ?? Platform.environment['LOCALAPPDATA'];
    if (outcome != 'installed' ||
        token == null ||
        !_tokenPattern.hasMatch(token) ||
        parsedExpected == null ||
        !parsedExpected.isStable ||
        root == null ||
        root.trim().isEmpty) {
      return null;
    }
    return WindowsUpdateSuccessConfirmation(
      token: token,
      expectedVersion: parsedExpected.toString(),
      localAppDataPath: root,
    );
  }

  File get confirmationFile => File(
    '${Directory(localAppDataPath).path}${Platform.pathSeparator}'
    'SuelosAR${Platform.pathSeparator}UpdateConfirmations'
    '${Platform.pathSeparator}$token.txt',
  );

  Future<String?> consume({
    required Future<String> Function() installedVersionReader,
    Duration timeout = const Duration(seconds: 35),
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    final expected = UpdateVersion.tryParse(expectedVersion);
    if (expected == null || !expected.isStable) return null;

    final marker = confirmationFile;
    final stopwatch = Stopwatch()..start();
    while (!await marker.exists()) {
      if (stopwatch.elapsed >= timeout) return null;
      await Future<void>.delayed(pollInterval);
    }

    String markerVersion;
    try {
      markerVersion = (await marker.readAsString()).trim();
    } on FileSystemException {
      return null;
    }
    try {
      await marker.delete();
    } on FileSystemException {
      return null;
    }

    if (markerVersion != 'version=$expectedVersion') return null;
    String installedText;
    try {
      installedText = await installedVersionReader();
    } catch (_) {
      return null;
    }
    final installed = UpdateVersion.tryParse(installedText);
    final comparison = installed == null
        ? null
        : UpdateVersion.compareRemoteToInstalled(
            remote: expected,
            installed: installed,
          );
    if (installed == null || !installed.isStable || comparison != 0) {
      return null;
    }
    return installedText;
  }
}
