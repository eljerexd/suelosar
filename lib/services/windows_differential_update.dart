import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'windows_installation_manifest.dart';
import 'windows_differential_zip_preflight.dart';
import 'windows_update_models.dart';

class WindowsDifferentialFile {
  const WindowsDifferentialFile({
    required this.path,
    required this.size,
    required this.sha256,
    required this.classification,
    this.changeType,
  });

  final String path;
  final int size;
  final String sha256;
  final String classification;
  final String? changeType;

  static WindowsDifferentialFile? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final path = json['path'];
    final size = json['size'];
    final hash = json['sha256'];
    final classification = json['classification'];
    final changeType = json['change_type'];
    if (!isSafeWindowsRelativePath(path) ||
        size is! int ||
        size < 0 ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        classification is! String ||
        classification.isEmpty ||
        (changeType != null &&
            changeType != 'added' &&
            changeType != 'modified') ||
        json['managed_by_updater'] != true) {
      return null;
    }
    return WindowsDifferentialFile(
      path: path as String,
      size: size,
      sha256: hash.toLowerCase(),
      classification: classification,
      changeType: changeType as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
    'classification': classification,
    'managed_by_updater': true,
    if (changeType != null) 'change_type': changeType,
  };
}

class WindowsDifferentialPackage {
  const WindowsDifferentialPackage({
    required this.name,
    required this.size,
    required this.sha256,
    required this.files,
  });

  final String name;
  final int size;
  final String sha256;
  final List<WindowsDifferentialFile> files;
}

class WindowsDifferentialManifest {
  const WindowsDifferentialManifest({
    required this.version,
    required this.minimumSupportedBaseline,
    required this.requiredInstallationSchema,
    required this.renderer,
    required this.compatibilityId,
    required this.package,
    required this.files,
    required this.removedFiles,
  });

  static const int schemaVersion = 1;
  static const int installationSchemaVersion = 1;
  static const int maximumPackageBytes = 512 * 1024 * 1024;
  static const String platform = 'windows-x64';
  static const String architecture = 'x64';

  static const String minimumDifferentialTargetVersion = '1.8.1';

  static bool supportsDifferentialTarget(UpdateVersion? target) {
    if (target == null || !target.isStable || target.buildNumber == null) {
      return false;
    }
    final minimum = UpdateVersion.tryParse(minimumDifferentialTargetVersion)!;
    return target.semanticVersion.compareTo(minimum.semanticVersion) >= 0;
  }

  static bool isTargetNewerThanBaseline({
    required UpdateVersion target,
    required UpdateVersion baseline,
  }) {
    if (!supportsDifferentialTarget(target) ||
        !baseline.isStable ||
        baseline.buildNumber == null) {
      return false;
    }
    final comparison = UpdateVersion.compareRemoteToInstalled(
      remote: target,
      installed: baseline,
    );
    return comparison != null && comparison > 0;
  }

  static String manifestAssetName(UpdateVersion version, String renderer) =>
      'SuelosAR-Differential-Manifest-${version.assetVersion}'
      '-win-x64-$renderer.json';

  static String packageAssetName(UpdateVersion version, String renderer) =>
      'SuelosAR-Differential-${version.assetVersion}'
      '-win-x64-$renderer.zip';

  final UpdateVersion version;
  final UpdateVersion minimumSupportedBaseline;
  final int requiredInstallationSchema;
  final String renderer;
  final String compatibilityId;
  final WindowsDifferentialPackage package;
  final List<WindowsDifferentialFile> files;
  final List<String> removedFiles;

  static WindowsDifferentialManifest? tryParse(
    Object? raw, {
    required String expectedVersion,
    required String expectedRenderer,
    required String expectedCompatibilityId,
  }) {
    if (raw is! Map<String, dynamic>) return null;
    final schema = raw['schema_version'];
    final requiredInstallationSchema = raw['required_installation_schema'];
    final appVersionText = raw['app_version'];
    final buildNumber = raw['build_number'];
    final versionText = raw['version'];
    final baselineText = raw['minimum_supported_baseline'];
    final platform = raw['platform'];
    final architecture = raw['architecture'];
    final renderer = raw['renderer'];
    final compatibility = raw['compatibility_id'];
    final packageJson = raw['package'];
    final filesJson = raw['files'];
    final addedJson = raw['added_files'];
    final modifiedJson = raw['modified_files'];
    final removedJson = raw['removed_files'];
    final version = appVersionText is String && buildNumber is int
        ? UpdateVersion.fromPackageInfo(
            version: appVersionText,
            buildNumber: '$buildNumber',
          )
        : (versionText is String ? UpdateVersion.tryParse(versionText) : null);
    final expected = UpdateVersion.tryParse(expectedVersion);
    final baseline = baselineText is String
        ? UpdateVersion.tryParse(baselineText)
        : null;

    final targetIsNewerThanBaseline =
        version != null &&
        baseline != null &&
        WindowsDifferentialManifest.isTargetNewerThanBaseline(
          target: version,
          baseline: baseline,
        );
    if (schema != schemaVersion ||
        requiredInstallationSchema != schemaVersion ||
        version == null ||
        !version.isStable ||
        version.buildNumber == null ||
        versionText != version.toString() ||
        expected == null ||
        version.toString() != expected.toString() ||
        !targetIsNewerThanBaseline ||
        !WindowsDifferentialManifest.supportsDifferentialTarget(version) ||
        !baseline.isStable ||
        baseline.buildNumber == null ||
        platform != WindowsDifferentialManifest.platform ||
        architecture != WindowsDifferentialManifest.architecture ||
        renderer != expectedRenderer ||
        renderer is! String ||
        renderer.isEmpty ||
        compatibility != expectedCompatibilityId ||
        packageJson is! Map<String, dynamic> ||
        filesJson is! List ||
        addedJson is! List ||
        modifiedJson is! List ||
        removedJson is! List) {
      return null;
    }

    final packageName = packageJson['name'];
    final packageSize = packageJson['size'];
    final packageHash = packageJson['sha256'];
    final packageFilesJson = packageJson['files'];
    if (packageName is! String ||
        packageName != packageAssetName(version, renderer) ||
        packageSize is! int ||
        packageSize <= 0 ||
        packageSize > maximumPackageBytes ||
        packageHash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(packageHash) ||
        packageFilesJson is! List ||
        packageFilesJson.isEmpty) {
      return null;
    }

    final files = <WindowsDifferentialFile>[];
    final seenFiles = <String>{};
    for (final item in filesJson) {
      final file = WindowsDifferentialFile.tryParse(item);
      if (file == null || !seenFiles.add(file.path.toLowerCase())) return null;
      files.add(file);
    }
    final packageFiles = <WindowsDifferentialFile>[];
    final seenPackageFiles = <String>{};
    final declaredAdded = <String>{};
    final declaredModified = <String>{};
    var totalPackageFileBytes = 0;
    for (final item in packageFilesJson) {
      final file = WindowsDifferentialFile.tryParse(item);
      if (file == null ||
          file.changeType == null ||
          !seenPackageFiles.add(file.path.toLowerCase()) ||
          !seenFiles.contains(file.path.toLowerCase())) {
        return null;
      }
      final target = files.singleWhere(
        (candidate) => candidate.path.toLowerCase() == file.path.toLowerCase(),
      );
      if (target.size != file.size || target.sha256 != file.sha256) return null;
      totalPackageFileBytes += file.size;
      if (totalPackageFileBytes > maximumPackageBytes) return null;
      (file.changeType == 'added' ? declaredAdded : declaredModified).add(
        file.path.toLowerCase(),
      );
      packageFiles.add(file);
    }
    final added = <String>{};
    for (final rawPath in addedJson) {
      if (!isSafeWindowsRelativePath(rawPath) ||
          !added.add((rawPath as String).toLowerCase())) {
        return null;
      }
    }
    final modified = <String>{};
    for (final rawPath in modifiedJson) {
      if (!isSafeWindowsRelativePath(rawPath) ||
          !modified.add((rawPath as String).toLowerCase())) {
        return null;
      }
    }
    if (!_sameStringSet(added, declaredAdded) ||
        !_sameStringSet(modified, declaredModified)) {
      return null;
    }
    final removed = <String>[];
    final seenRemoved = <String>{};
    for (final value in removedJson) {
      if (!isSafeWindowsRelativePath(value) ||
          !seenRemoved.add((value as String).toLowerCase()) ||
          seenFiles.contains(value.toLowerCase())) {
        return null;
      }
      removed.add(value);
    }
    if (files.isEmpty || packageFiles.isEmpty) return null;
    return WindowsDifferentialManifest(
      version: version,
      minimumSupportedBaseline: baseline,
      requiredInstallationSchema: requiredInstallationSchema as int,
      renderer: renderer,
      compatibilityId: compatibility,
      package: WindowsDifferentialPackage(
        name: packageName,
        size: packageSize,
        sha256: packageHash.toLowerCase(),
        files: List.unmodifiable(packageFiles),
      ),
      files: List.unmodifiable(files),
      removedFiles: List.unmodifiable(removed),
    );
  }

  bool supportsLocalManifest(Map<String, dynamic> local) {
    if (!WindowsInstallationManifestService.isValidManifest(local) ||
        local['schema_version'] != requiredInstallationSchema ||
        local['platform'] != 'windows-x64' ||
        local['renderer'] != renderer ||
        local['compatibility_id'] != compatibilityId) {
      return false;
    }
    final localVersion = UpdateVersion.fromPackageInfo(
      version: local['app_version']! as String,
      buildNumber: '${local['build_number']}',
    );
    return localVersion != null &&
        localVersion.toString() == minimumSupportedBaseline.toString();
  }

  static bool _sameStringSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'version': version.toString(),
    'app_version': version.semanticVersion.toDisplayString(),
    'build_number': version.buildNumber,
    'required_installation_schema': requiredInstallationSchema,
    'minimum_supported_baseline': minimumSupportedBaseline.toString(),
    'platform': platform,
    'architecture': architecture,
    'renderer': renderer,
    'compatibility_id': compatibilityId,
    'package': {
      'name': package.name,
      'size': package.size,
      'sha256': package.sha256,
      'files': package.files.map((file) => file.toJson()).toList(),
    },
    'files': files.map((file) => file.toJson()).toList(),
    'added_files': package.files
        .where((file) => file.changeType == 'added')
        .map((file) => file.path)
        .toList(),
    'modified_files': package.files
        .where((file) => file.changeType == 'modified')
        .map((file) => file.path)
        .toList(),
    'removed_files': removedFiles,
  };
}

class PreparedWindowsDifferentialUpdate {
  const PreparedWindowsDifferentialUpdate({
    required this.stagingDirectory,
    required this.applyList,
    required this.applyListSha256,
    required this.removeList,
    required this.removeListSha256,
    required this.targetManifest,
    required this.targetManifestSha256,
    required this.previousManifest,
    required this.previousManifestSha256,
    required this.targetVerifyList,
    required this.targetVerifyListSha256,
    required this.previousVerifyList,
    required this.previousVerifyListSha256,
  });

  final Directory stagingDirectory;
  final File applyList;
  final String applyListSha256;
  final File removeList;
  final String removeListSha256;
  final File targetManifest;
  final String targetManifestSha256;
  final File previousManifest;
  final String previousManifestSha256;
  final File targetVerifyList;
  final String targetVerifyListSha256;
  final File previousVerifyList;
  final String previousVerifyListSha256;
}

class WindowsDifferentialPackageStager {
  const WindowsDifferentialPackageStager._();

  static Future<PreparedWindowsDifferentialUpdate> stage({
    required File packageFile,
    required WindowsDifferentialManifest remote,
    required Map<String, dynamic> localManifest,
    required File localManifestFile,
    required Directory installDirectory,
    required Directory updateDirectory,
  }) async {
    if (!remote.supportsLocalManifest(localManifest)) {
      throw const FormatException(
        'El manifiesto local no es un baseline compatible.',
      );
    }
    if (!await WindowsInstallationManifestService.verifyManagedInventory(
      installDirectory: installDirectory,
      manifest: localManifest,
    )) {
      throw const FormatException(
        'Los archivos administrados no coinciden con el manifiesto local.',
      );
    }
    final localFiles = <String, Map<String, dynamic>>{};
    for (final raw in localManifest['files'] as List) {
      final file = raw as Map<String, dynamic>;
      if (file['managed_by_updater'] == true) {
        localFiles[(file['path']! as String).toLowerCase()] = file;
      }
    }
    final remoteFiles = {
      for (final file in remote.files) file.path.toLowerCase(): file,
    };
    final expectedApply = <String, String>{};
    final expectedRemoved = <String>{};
    for (final key in {...localFiles.keys, ...remoteFiles.keys}) {
      final before = localFiles[key];
      final after = remoteFiles[key];
      if (before == null) {
        expectedApply[key] = 'added';
      } else if (after == null) {
        expectedRemoved.add(key);
      } else if (before['size'] != after.size ||
          before['sha256'] != after.sha256) {
        expectedApply[key] = 'modified';
      }
    }
    final declaredApply = {
      for (final file in remote.package.files)
        file.path.toLowerCase(): file.changeType!,
    };
    final declaredRemoved = remote.removedFiles
        .map((path) => path.toLowerCase())
        .toSet();
    if (expectedApply.length != declaredApply.length ||
        expectedApply.entries.any(
          (entry) => declaredApply[entry.key] != entry.value,
        ) ||
        !_sameSet(expectedRemoved, declaredRemoved)) {
      throw const FormatException(
        'El paquete no coincide con las diferencias declaradas para el baseline.',
      );
    }

    final archiveLength = await packageFile.length();
    if (archiveLength > WindowsDifferentialManifest.maximumPackageBytes ||
        archiveLength != remote.package.size) {
      throw const FormatException(
        'El tamaño del ZIP no coincide con el manifiesto o excede el límite.',
      );
    }
    final zipBytes = await packageFile.readAsBytes();
    if (zipBytes.length != remote.package.size ||
        sha256.convert(zipBytes).toString() != remote.package.sha256) {
      throw const FormatException(
        'El ZIP no coincide con el tamaño o SHA-256 declarado.',
      );
    }
    final preflightEntries = WindowsDifferentialZipPreflight.inspect(
      zipBytes,
      expectedFiles: {
        for (final file in remote.package.files) file.path: file.size,
      },
    );
    final preflightByPath = {
      for (final entry in preflightEntries) entry.path.toLowerCase(): entry,
    };
    final archive = ZipDecoder().decodeBytes(
      zipBytes,
      verify: true,
      throwOnError: true,
    );
    final entries = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          !isSafeWindowsRelativePath(entry.name)) {
        throw const FormatException(
          'El ZIP contiene una entrada no permitida.',
        );
      }
      final key = entry.name.toLowerCase();
      final preflight = preflightByPath[key];
      if (entries.containsKey(key) ||
          preflight == null ||
          preflight.path != entry.name ||
          preflight.expandedSize != entry.size) {
        throw const FormatException(
          'Una entrada ZIP difiere de su preflight o está duplicada.',
        );
      }
      entries[key] = entry;
    }
    if (!_sameSet(entries.keys.toSet(), declaredApply.keys.toSet())) {
      throw const FormatException(
        'El ZIP contiene archivos inesperados o faltantes.',
      );
    }

    final stagingDirectory = Directory(
      '${updateDirectory.path}${Platform.pathSeparator}staged',
    );
    if (await stagingDirectory.exists()) {
      throw const FileSystemException('El directorio de staging ya existe.');
    }
    await stagingDirectory.create(recursive: false);
    try {
      for (final file in remote.package.files) {
        final entry = entries[file.path.toLowerCase()]!;
        if (entry.size != file.size) {
          throw FormatException('Tamaño inesperado para ${file.path}.');
        }
        final bytes = entry.readBytes();
        if (bytes == null ||
            bytes.length != file.size ||
            sha256.convert(bytes).toString() != file.sha256) {
          throw FormatException('SHA-256 inválido para ${file.path}.');
        }
        final target = _fileBelow(stagingDirectory, file.path);
        await target.parent.create(recursive: true);
        final parentRoot = await target.parent.resolveSymbolicLinks();
        if (!_isContained(
          await stagingDirectory.resolveSymbolicLinks(),
          parentRoot,
        )) {
          throw FormatException('La ruta sale del staging: ${file.path}.');
        }
        await target.writeAsBytes(bytes, flush: true);
      }

      final localJsonText = await localManifestFile.readAsString();
      final targetManifest = File(
        '${updateDirectory.path}${Platform.pathSeparator}target-manifest.json',
      );
      final targetFiles = <Map<String, Object?>>[
        ...remote.files.map((file) => file.toJson()),
        for (final raw in localManifest['files'] as List)
          if (raw is Map<String, dynamic> && raw['managed_by_updater'] != true)
            Map<String, Object?>.from(raw),
      ]..sort((a, b) => (a['path']! as String).compareTo(b['path']! as String));
      final targetLocalManifest = <String, Object?>{
        'schema_version': WindowsDifferentialManifest.schemaVersion,
        'app_version': remote.version.semanticVersion.toDisplayString(),
        'build_number': remote.version.buildNumber,
        'platform': 'windows-x64',
        'renderer': remote.renderer,
        'compatibility_id': remote.compatibilityId,
        'installation_id': localManifest['installation_id'],
        'generated_at_utc': DateTime.now().toUtc().toIso8601String(),
        'files': targetFiles,
      };
      final targetManifestBytes = utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert(targetLocalManifest)}\n',
      );
      await targetManifest.writeAsBytes(targetManifestBytes, flush: true);
      final applyList = File(
        '${updateDirectory.path}${Platform.pathSeparator}apply.tsv',
      );
      final applyText = remote.package.files
          .map(
            (file) =>
                '${file.path}\t${file.size}\t${file.sha256}\t${file.changeType}',
          )
          .join('\n');
      await applyList.writeAsString('$applyText\n', flush: true);
      final removeList = File(
        '${updateDirectory.path}${Platform.pathSeparator}remove.txt',
      );
      final removeText = remote.removedFiles.join('\n');
      await removeList.writeAsString(
        removeText.isEmpty ? '' : '$removeText\n',
        flush: true,
      );
      final previousManifest = File(
        '${updateDirectory.path}${Platform.pathSeparator}previous-manifest.json',
      );
      await previousManifest.writeAsString(localJsonText, flush: true);

      final targetVerifyList = File(
        '${updateDirectory.path}${Platform.pathSeparator}target-verify.tsv',
      );
      final targetVerifyText = remote.files
          .map((file) => '${file.path}\t${file.size}\t${file.sha256}')
          .join('\n');
      await targetVerifyList.writeAsString(
        targetVerifyText.isEmpty ? '' : '$targetVerifyText\n',
        flush: true,
      );
      final previousVerifyList = File(
        '${updateDirectory.path}${Platform.pathSeparator}previous-verify.tsv',
      );
      final previousManaged = localFiles.values.toList()
        ..sort(
          (a, b) => (a['path']! as String).compareTo(b['path']! as String),
        );
      final previousVerifyText = previousManaged
          .map((file) => '${file['path']}\t${file['size']}\t${file['sha256']}')
          .join('\n');
      await previousVerifyList.writeAsString(
        previousVerifyText.isEmpty ? '' : '$previousVerifyText\n',
        flush: true,
      );

      return PreparedWindowsDifferentialUpdate(
        stagingDirectory: stagingDirectory,
        applyList: applyList,
        applyListSha256: await _fileSha256(applyList),
        removeList: removeList,
        removeListSha256: await _fileSha256(removeList),
        targetManifest: targetManifest,
        targetManifestSha256: await _fileSha256(targetManifest),
        previousManifest: previousManifest,
        previousManifestSha256: await _fileSha256(previousManifest),
        targetVerifyList: targetVerifyList,
        targetVerifyListSha256: await _fileSha256(targetVerifyList),
        previousVerifyList: previousVerifyList,
        previousVerifyListSha256: await _fileSha256(previousVerifyList),
      );
    } catch (_) {
      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  static File _fileBelow(Directory root, String relative) {
    final components = relative.split('/');
    return File(
      <String>[root.path, ...components].join(Platform.pathSeparator),
    );
  }

  static Future<String> _fileSha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _isContained(String root, String path) {
    final base = root
        .toLowerCase()
        .replaceAll('/', '\\')
        .replaceAll(RegExp(r'\\+$'), '');
    final candidate = path.toLowerCase().replaceAll('/', '\\');
    return candidate == base || candidate.startsWith('$base\\');
  }
}

bool isSafeWindowsRelativePath(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      value.contains('\\') ||
      value.contains(':') ||
      RegExp(r'[\x00-\x1f<>"|?*]').hasMatch(value)) {
    return false;
  }
  for (final part in value.split('/')) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
          caseSensitive: false,
        ).hasMatch(part)) {
      return false;
    }
  }
  return true;
}
