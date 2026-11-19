import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'windows_manifest_package_info_stub.dart'
    if (dart.library.ui) 'windows_manifest_package_info_flutter.dart'
    as package_info;
import 'windows_update_models.dart';

/// Creates the 1.8.1 migration baseline from files actually installed on disk.
///
/// It is intentionally not an updater: no files are replaced or removed.
class WindowsInstallationManifestService {
  WindowsInstallationManifestService({
    required this.installDirectory,
    required this.manifestFile,
    required this.version,
    required this.buildNumber,
    required this.renderer,
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  static const int schemaVersion = 1;
  static const String compatibilityId = 'suelosar-windows-x64-v1';
  static const String transitionVersion = '1.8.1';
  static const String manifestDirectoryName = 'Manifests';
  static const String manifestFileName = 'installation-manifest.json';

  final Directory installDirectory;
  final File manifestFile;
  final String version;
  final int buildNumber;
  final String renderer;
  final DateTime Function() _clock;
  final Random _random;

  /// Ensures a supported Windows installation has a baseline from its files.
  ///
  /// The full Setup is also the recovery path for later releases. After it
  /// replaces application files, the next launch must refresh a missing or
  /// stale local manifest so the installation can participate in future
  /// differential updates.
  Future<bool> ensureTransitionBaseline() async {
    final installed = UpdateVersion.fromPackageInfo(
      version: version,
      buildNumber: '$buildNumber',
    );
    final transition = SemanticVersion.tryParse(transitionVersion)!;
    if (!Platform.isWindows ||
        installed == null ||
        !installed.isStable ||
        installed.semanticVersion.compareTo(transition) < 0) {
      return false;
    }
    final existing = await readManifest(manifestFile);
    if (existing != null &&
        existing['schema_version'] == schemaVersion &&
        existing['app_version'] ==
            installed.semanticVersion.toDisplayString() &&
        existing['build_number'] == buildNumber &&
        existing['compatibility_id'] == compatibilityId) {
      return true;
    }

    final previousId = existing?['installation_id'];
    final installationId =
        previousId is String && RegExp(r'^[a-f0-9-]{36}$').hasMatch(previousId)
        ? previousId
        : _newInstallationId();
    final manifest = await createManifest(
      installDirectory: installDirectory,
      appVersion: installed.semanticVersion.toDisplayString(),
      buildNumber: buildNumber,
      renderer: renderer,
      installationId: installationId,
      generatedAt: _clock().toUtc(),
    );
    await writeAtomically(manifestFile, manifest);
    return true;
  }

  Future<Map<String, Object?>> createManifest({
    required Directory installDirectory,
    required String appVersion,
    required int buildNumber,
    required String renderer,
    required String installationId,
    required DateTime generatedAt,
  }) async {
    final root = await installDirectory.resolveSymbolicLinks();
    final files = <Map<String, Object?>>[];
    await for (final entity in installDirectory.list(recursive: true)) {
      if (entity is! File) continue;
      final resolved = await entity.resolveSymbolicLinks();
      if (!_isWithin(root, resolved)) continue;
      final relative = _relativePath(root, resolved);
      if (_isInstallerOwnedMetadata(relative)) continue;
      final classification = _classify(relative);
      final stat = await entity.stat();
      final digest = await sha256.bind(entity.openRead()).first;
      files.add({
        'path': relative,
        'size': stat.size,
        'sha256': digest.toString(),
        'classification': classification ?? 'unmanaged',
        'managed_by_updater': classification != null,
      });
    }
    files.sort(
      (a, b) => (a['path']! as String).compareTo(b['path']! as String),
    );
    if (files.isEmpty) {
      throw const FileSystemException('No managed application files found.');
    }
    return {
      'schema_version': schemaVersion,
      'app_version': appVersion,
      'build_number': buildNumber,
      'platform': 'windows-x64',
      'renderer': renderer,
      'compatibility_id': compatibilityId,
      'installation_id': installationId,
      'generated_at_utc': generatedAt.toIso8601String(),
      'files': files,
    };
  }

  static Future<Map<String, Object?>?> readManifest(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || !isValidManifest(decoded)) {
        return null;
      }
      return Map<String, Object?>.from(decoded);
    } on Object {
      return null;
    }
  }

  static bool isValidManifest(Map<String, dynamic> manifest) {
    final appVersion = manifest['app_version'];
    final parsedAppVersion = appVersion is String
        ? UpdateVersion.tryParse(appVersion)
        : null;
    if (manifest['schema_version'] != schemaVersion ||
        manifest['platform'] != 'windows-x64' ||
        manifest['compatibility_id'] != compatibilityId ||
        parsedAppVersion == null ||
        !parsedAppVersion.isStable ||
        parsedAppVersion.buildNumber != null ||
        manifest['build_number'] is! int ||
        (manifest['build_number'] as int) < 0 ||
        (manifest['build_number'] as int) > 65535 ||
        manifest['renderer'] is! String ||
        (manifest['renderer'] as String).isEmpty ||
        manifest['installation_id'] is! String ||
        !RegExp(r'^[a-f0-9-]{36}$')
            .hasMatch(manifest['installation_id'] as String) ||
        DateTime.tryParse(manifest['generated_at_utc'] as String? ?? '') ==
            null ||
        manifest['files'] is! List) {
      return false;
    }
    final seen = <String>{};
    for (final item in manifest['files'] as List) {
      if (item is! Map<String, dynamic> ||
          !_isValidRelativePath(item['path']) ||
          item['size'] is! int ||
          (item['size'] as int) < 0 ||
          item['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['sha256'] as String) ||
          item['classification'] is! String ||
          item['managed_by_updater'] is! bool ||
          !seen.add((item['path'] as String).toLowerCase())) {
        return false;
      }
    }
    return (manifest['files'] as List).isNotEmpty;
  }

  /// Verifies the on-disk bytes represented by the managed portion of a
  /// previously generated manifest. Unmanaged files remain outside the update
  /// baseline and are deliberately not hashed here.
  static Future<bool> verifyManagedInventory({
    required Directory installDirectory,
    required Map<String, dynamic> manifest,
  }) async {
    if (!isValidManifest(manifest)) return false;
    try {
      final root = await installDirectory.resolveSymbolicLinks();
      for (final raw in manifest['files'] as List) {
        final entry = raw as Map<String, dynamic>;
        if (entry['managed_by_updater'] != true) continue;
        final relativePath = entry['path']! as String;
        if (!_isValidRelativePath(relativePath)) return false;
        final file = File(
          <String>[
            root,
            ...relativePath.split('/'),
          ].join(Platform.pathSeparator),
        );
        if (!await file.exists()) return false;
        final resolved = await file.resolveSymbolicLinks();
        if (!_isWithin(root, resolved)) return false;
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size != entry['size']) {
          return false;
        }
        final actualHash = await sha256.bind(file.openRead()).first;
        if (actualHash.toString() != entry['sha256']) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Future<void> writeAtomically(
    File target,
    Map<String, Object?> manifest,
  ) async {
    await target.parent.create(recursive: true);
    final nonce = List.generate(
      32,
      (_) => '0123456789abcdef'[Random.secure().nextInt(16)],
    ).join();
    final temporary = File('${target.path}.$nonce.tmp');
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
        flush: true,
      );
      await temporary.rename(target.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static String _relativePath(String root, String path) =>
      path.substring(root.length + 1).replaceAll('\\', '/');

  static bool _isWithin(String root, String path) {
    final normalizedRoot = root.toLowerCase().replaceAll(
      RegExp(r'[\\/]+$'),
      '',
    );
    final normalizedPath = path.toLowerCase().replaceAll('/', '\\');
    return normalizedPath.startsWith('$normalizedRoot\\');
  }

  static bool _isValidRelativePath(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      !value.startsWith('/') &&
      !value.contains('\\') &&
      !value.contains(':') &&
      !value
          .split('/')
          .any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(r'[\x00-\x1f<>"|?*]').hasMatch(part) ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
                  caseSensitive: false,
                ).hasMatch(part),
          );

  static bool _isInstallerOwnedMetadata(String path) {
    final name = path.split('/').last.toLowerCase();
    return RegExp(r'^unins\d+\.(exe|dat|msg)$').hasMatch(name);
  }

  static String? _classify(String path) {
    final normalized = path.toLowerCase();
    if (normalized == 'data/app.so') return 'runtime';
    if (normalized.startsWith('data/flutter_assets/')) {
      if (normalized.endsWith('.pmtiles')) return 'pmtiles';
      if (normalized.endsWith('.pdf')) return 'pdf';
      return 'application-resource';
    }
    if (RegExp(r'^data/(buenos_aires|cordoba|santa_fe)_pmtiles/')
        .hasMatch(normalized)) {
      return normalized.endsWith('.pmtiles')
          ? 'pmtiles'
          : 'application-resource';
    }
    final name = normalized.split('/').last;
    if (name == 'suelosar.exe' || name == 'suelosar_update_helper.exe') {
      return 'executable';
    }
    if (name == 'flutter_windows.dll' || name == 'maplibre-native-c.dll') {
      return 'runtime';
    }
    if (name.endsWith('_plugin.dll') ||
        name == 'pdfium.dll' ||
        name == 'rhttp.dll') {
      return 'native-library';
    }
    if (name.endsWith('.lib') || name.endsWith('.exp')) return null;
    return null;
  }

  String _newInstallationId() => _randomToken(length: 36);

  String _randomToken({int length = 32}) {
    const alphabet = '0123456789abcdef';
    return List.generate(length, (_) => alphabet[_random.nextInt(16)]).join();
  }

  /// Builds a service from actual Windows executable metadata and paths.
  static Future<WindowsInstallationManifestService?>
  forCurrentWindowsApp() async {
    if (!Platform.isWindows) return null;
    final info = await package_info.readCurrentPackageInfo();
    if (info == null) return null;
    final parsed = UpdateVersion.fromPackageInfo(
      version: info.version,
      buildNumber: info.buildNumber,
    );
    final local = Platform.environment['LOCALAPPDATA'];
    if (parsed == null || local == null || local.isEmpty) return null;
    final renderer =
        const bool.fromEnvironment(
          'SUelosAR_MAPLIBRE_NATIVE',
          defaultValue: false,
        )
        ? 'maplibre-native'
        : 'flutter-map-fallback';
    return WindowsInstallationManifestService(
      installDirectory: Directory(
        File(Platform.resolvedExecutable).parent.path,
      ),
      manifestFile: File(
        '$local${Platform.pathSeparator}SuelosAR'
        '${Platform.pathSeparator}$manifestDirectoryName'
        '${Platform.pathSeparator}$manifestFileName',
      ),
      version: parsed.toString(),
      buildNumber: parsed.buildNumber ?? 0,
      renderer: renderer,
    );
  }
}

class WindowsManifestComparison {
  const WindowsManifestComparison({
    required this.compatible,
    this.reason,
    this.newFiles = const [],
    this.modifiedFiles = const [],
    this.removedFiles = const [],
    this.unchangedFiles = const [],
  });

  final bool compatible;
  final String? reason;
  final List<String> newFiles;
  final List<String> modifiedFiles;
  final List<String> removedFiles;
  final List<String> unchangedFiles;

  static WindowsManifestComparison compare(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    if (!WindowsInstallationManifestService.isValidManifest(local) ||
        !WindowsInstallationManifestService.isValidManifest(remote)) {
      return const WindowsManifestComparison(
        compatible: false,
        reason: 'invalid-manifest',
      );
    }
    if (local['compatibility_id'] != remote['compatibility_id'] ||
        local['platform'] != remote['platform'] ||
        local['schema_version'] != remote['schema_version']) {
      return const WindowsManifestComparison(
        compatible: false,
        reason: 'incompatible-installation',
      );
    }
    final minimumText = remote['minimum_supported_baseline'];
    if (minimumText != null) {
      if (minimumText is! String) {
        return const WindowsManifestComparison(
          compatible: false,
          reason: 'invalid-minimum-baseline',
        );
      }
      final minimum = UpdateVersion.tryParse(minimumText);
      final installed = UpdateVersion.fromPackageInfo(
        version: local['app_version']! as String,
        buildNumber: '${local['build_number']}',
      );
      if (minimum == null || installed == null) {
        return const WindowsManifestComparison(
          compatible: false,
          reason: 'invalid-minimum-baseline',
        );
      }
      final meetsMinimum = UpdateVersion.compareRemoteToInstalled(
        remote: installed,
        installed: minimum,
      );
      if (meetsMinimum == null || meetsMinimum < 0) {
        return const WindowsManifestComparison(
          compatible: false,
          reason: 'unsupported-baseline',
        );
      }
    }

    final localFiles = _managedFiles(local);
    final remoteFiles = _managedFiles(remote);
    final added = <String>[];
    final modified = <String>[];
    final removed = <String>[];
    final unchanged = <String>[];
    for (final key in {...localFiles.keys, ...remoteFiles.keys}) {
      final before = localFiles[key];
      final after = remoteFiles[key];
      if (before == null) {
        added.add(after!['path']! as String);
      } else if (after == null) {
        removed.add(before['path']! as String);
      } else if (before['size'] != after['size'] ||
          before['sha256'] != after['sha256']) {
        modified.add(after['path']! as String);
      } else {
        unchanged.add(after['path']! as String);
      }
    }
    added.sort();
    modified.sort();
    removed.sort();
    unchanged.sort();
    return WindowsManifestComparison(
      compatible: true,
      newFiles: List.unmodifiable(added),
      modifiedFiles: List.unmodifiable(modified),
      removedFiles: List.unmodifiable(removed),
      unchangedFiles: List.unmodifiable(unchanged),
    );
  }

  static Map<String, Map<String, dynamic>> _managedFiles(
    Map<String, dynamic> manifest,
  ) {
    final result = <String, Map<String, dynamic>>{};
    for (final raw in manifest['files'] as List) {
      final file = raw as Map<String, dynamic>;
      if (file['managed_by_updater'] == true) {
        result[(file['path']! as String).toLowerCase()] = file;
      }
    }
    return result;
  }
}
