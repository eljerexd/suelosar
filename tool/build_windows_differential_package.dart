import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'package:suelosar/services/windows_differential_update.dart';
import 'package:suelosar/services/windows_installation_manifest.dart';
import 'package:suelosar/services/windows_update_models.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final baselineFile = File(_required(options, 'baseline-manifest'));
  final targetDirectory = Directory(_required(options, 'target-dir'));
  final outputDirectory = Directory(_required(options, 'output-dir'));
  final version = UpdateVersion.tryParse(_required(options, 'version'));
  final renderer = _required(options, 'renderer');
  if (version == null ||
      !WindowsDifferentialManifest.supportsDifferentialTarget(version)) {
    throw const FormatException(
      'El target diferencial debe ser estable, incluir build numérico y ser '
      '1.8.1 o posterior.',
    );
  }
  if (renderer != 'maplibre-native' && renderer != 'flutter-map-fallback') {
    throw const FormatException('Renderer no admitido.');
  }
  if (!await baselineFile.exists() || !await targetDirectory.exists()) {
    throw const FileSystemException(
      'Falta el manifiesto baseline o el directorio Release target.',
    );
  }
  if (await outputDirectory.exists()) {
    throw FileSystemException(
      'El directorio de salida ya existe; no se sobrescribe ningún candidato.',
      outputDirectory.path,
    );
  }

  final baseline = await WindowsInstallationManifestService.readManifest(
    baselineFile,
  );
  if (baseline == null ||
      baseline['platform'] != WindowsDifferentialManifest.platform ||
      baseline['renderer'] != renderer ||
      baseline['compatibility_id'] !=
          WindowsInstallationManifestService.compatibilityId) {
    throw const FormatException('El manifiesto baseline no es compatible.');
  }
  final baselineVersion = UpdateVersion.fromPackageInfo(
    version: baseline['app_version']! as String,
    buildNumber: '${baseline['build_number']}',
  );
  if (baselineVersion == null || !baselineVersion.isStable) {
    throw const FormatException('La versión del baseline no es válida.');
  }
  if (!WindowsDifferentialManifest.isTargetNewerThanBaseline(
    target: version,
    baseline: baselineVersion,
  )) {
    throw const FormatException(
      'El target diferencial debe ser posterior al baseline declarado.',
    );
  }

  final inventoryService = WindowsInstallationManifestService(
    installDirectory: targetDirectory,
    manifestFile: File('unused-target-manifest.json'),
    version: version.toString(),
    buildNumber: version.buildNumber!,
    renderer: renderer,
  );
  final targetManifest = await inventoryService.createManifest(
    installDirectory: targetDirectory,
    appVersion: version.semanticVersion.toDisplayString(),
    buildNumber: version.buildNumber!,
    renderer: renderer,
    installationId: baseline['installation_id']! as String,
    generatedAt: DateTime.now().toUtc(),
  );
  final targetManaged = <String, Map<String, dynamic>>{
    for (final raw in targetManifest['files']! as List)
      if (raw is Map<String, dynamic> && raw['managed_by_updater'] == true)
        (raw['path']! as String).toLowerCase(): raw,
  };
  final baselineManaged = <String, Map<String, dynamic>>{
    for (final raw in baseline['files']! as List)
      if (raw is Map<String, dynamic> && raw['managed_by_updater'] == true)
        (raw['path']! as String).toLowerCase(): raw,
  };
  final additions = <Map<String, Object?>>[];
  final modifications = <Map<String, Object?>>[];
  for (final entry in targetManaged.entries) {
    if (!isSafeWindowsRelativePath(entry.value['path'])) {
      throw FormatException('Ruta target no válida: ${entry.value['path']}');
    }
    final before = baselineManaged[entry.key];
    if (before == null) {
      additions.add({...entry.value, 'change_type': 'added'});
    } else if (before['size'] != entry.value['size'] ||
        before['sha256'] != entry.value['sha256']) {
      modifications.add({...entry.value, 'change_type': 'modified'});
    }
  }
  final removed = <String>[];
  for (final entry in baselineManaged.entries) {
    if (!targetManaged.containsKey(entry.key)) {
      if (!isSafeWindowsRelativePath(entry.value['path'])) {
        throw FormatException(
          'Ruta removida no válida: ${entry.value['path']}',
        );
      }
      removed.add(entry.value['path']! as String);
    }
  }
  final packageFiles = [...additions, ...modifications]
    ..sort((a, b) => (a['path']! as String).compareTo(b['path']! as String));
  removed.sort();
  if (packageFiles.isEmpty && removed.isEmpty) {
    throw const FormatException('No hay cambios para empaquetar.');
  }
  final totalChangedBytes = packageFiles.fold<int>(
    0,
    (total, file) => total + (file['size']! as int),
  );
  if (totalChangedBytes > WindowsDifferentialManifest.maximumPackageBytes) {
    throw const FormatException(
      'El delta supera el límite seguro de memoria; publicá y usá el Setup completo.',
    );
  }

  final archive = Archive();
  for (final entry in packageFiles) {
    final relative = entry['path']! as String;
    final file = File(
      <String>[
        await targetDirectory.resolveSymbolicLinks(),
        ...relative.split('/'),
      ].join(Platform.pathSeparator),
    );
    if (!await file.exists()) {
      throw FileSystemException('Falta un archivo target.', file.path);
    }
    final resolved = await file.resolveSymbolicLinks();
    if (!_isWithin(await targetDirectory.resolveSymbolicLinks(), resolved)) {
      throw FileSystemException(
        'El archivo sale del directorio Release.',
        file.path,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != entry['size'] ||
        sha256.convert(bytes).toString() != entry['sha256']) {
      throw FileSystemException('Tamaño o hash target cambió.', file.path);
    }
    archive.addFile(ArchiveFile(relative, bytes.length, bytes));
  }

  final encoded = ZipEncoder().encode(archive);
  if (encoded.isEmpty) {
    throw const FileSystemException('No se pudo crear el ZIP diferencial.');
  }
  final packageName = WindowsDifferentialManifest.packageAssetName(
    version,
    renderer,
  );
  final packageHash = sha256.convert(encoded).toString();
  final packageInventory = <Map<String, Object?>>[
    for (final raw in packageFiles)
      {
        'path': raw['path'],
        'size': raw['size'],
        'sha256': raw['sha256'],
        'classification': raw['classification'],
        'managed_by_updater': true,
        'change_type': raw['change_type'],
      },
  ];
  final remoteManifest = <String, Object?>{
    'schema_version': WindowsDifferentialManifest.schemaVersion,
    'version': version.toString(),
    'app_version': version.semanticVersion.toDisplayString(),
    'build_number': version.buildNumber,
    'platform': WindowsDifferentialManifest.platform,
    'architecture': WindowsDifferentialManifest.architecture,
    'renderer': renderer,
    'required_installation_schema':
        WindowsDifferentialManifest.installationSchemaVersion,
    'compatibility_id': WindowsInstallationManifestService.compatibilityId,
    'minimum_supported_baseline': baselineVersion.toString(),
    'files':
        targetManaged.values
            .map((entry) => Map<String, Object?>.from(entry))
            .toList()
          ..sort(
            (a, b) => (a['path']! as String).compareTo(b['path']! as String),
          ),
    'added_files': additions.map((entry) => entry['path']).toList(),
    'modified_files': modifications.map((entry) => entry['path']).toList(),
    'removed_files': removed,
    'package': {
      'name': packageName,
      'size': encoded.length,
      'sha256': packageHash,
      'files': packageInventory,
    },
  };
  final parsed = WindowsDifferentialManifest.tryParse(
    remoteManifest,
    expectedVersion: version.toString(),
    expectedRenderer: renderer,
    expectedCompatibilityId: WindowsInstallationManifestService.compatibilityId,
  );
  if (parsed == null) {
    throw const FormatException('El manifiesto generado no supera su parser.');
  }

  await outputDirectory.create(recursive: true);
  final packageFile = File(
    '${outputDirectory.path}${Platform.pathSeparator}$packageName',
  );
  await packageFile.writeAsBytes(encoded, flush: true);
  final finalHash = await _sha256(packageFile);
  if (finalHash != packageHash) {
    throw const FileSystemException('El ZIP escrito no coincide con su hash.');
  }
  final manifestName = WindowsDifferentialManifest.manifestAssetName(
    version,
    renderer,
  );
  final manifestFile = File(
    '${outputDirectory.path}${Platform.pathSeparator}$manifestName',
  );
  final manifestBytes = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(remoteManifest)}\n',
  );
  await manifestFile.writeAsBytes(manifestBytes, flush: true);
  final manifestHash = sha256.convert(manifestBytes).toString();
  final generatedAt = DateTime.now().toUtc().toIso8601String();
  final baselineHash = await _sha256(baselineFile);
  final buildManifest = <String, Object?>{
    'schema_version': 1,
    'app_version': version.semanticVersion.toDisplayString(),
    'build_number': version.buildNumber,
    'baseline_version': baselineVersion.toString(),
    'baseline_manifest_sha256': baselineHash,
    'generated_at_utc': generatedAt,
    'renderer': renderer,
    'classification_counts': {
      'added': additions.length,
      'modified': modifications.length,
      'removed': removed.length,
      'unchanged':
          targetManaged.length - additions.length - modifications.length,
    },
    'package': {
      'path': packageFile.path,
      'size': await packageFile.length(),
      'sha256': finalHash,
    },
    'remote_manifest': {
      'path': manifestFile.path,
      'size': await manifestFile.length(),
      'sha256': manifestHash,
    },
  };
  final buildManifestFile = File(
    '${outputDirectory.path}${Platform.pathSeparator}build-manifest.json',
  );
  await buildManifestFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(buildManifest)}\n',
    flush: true,
  );
  await File('${packageFile.path}.sha256')
      .writeAsString('$finalHash  $packageName\n', flush: true);
  await File('${manifestFile.path}.sha256')
      .writeAsString('$manifestHash  $manifestName\n', flush: true);
  final compatibility = <String, Object?>{
    'platform': WindowsDifferentialManifest.platform,
    'architecture': WindowsDifferentialManifest.architecture,
    'renderer': renderer,
    'compatibility_id': WindowsInstallationManifestService.compatibilityId,
    'required_installation_schema':
        WindowsDifferentialManifest.installationSchemaVersion,
    'minimum_supported_baseline': baselineVersion.toString(),
  };
  await File(
    '${outputDirectory.path}${Platform.pathSeparator}compatibility.json',
  ).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(compatibility)}\n',
    flush: true,
  );

  final verifiedZip = ZipDecoder().decodeBytes(
    await packageFile.readAsBytes(),
    verify: true,
    throwOnError: true,
  );
  if (verifiedZip.files.length != packageFiles.length ||
      verifiedZip.files.any((file) => !file.isFile || file.isSymbolicLink)) {
    throw const FormatException('La validación final del ZIP falló.');
  }
  stdout.writeln('version=${version.toString()}');
  stdout.writeln('baseline=${baselineVersion.toString()}');
  stdout.writeln('added=${additions.length}');
  stdout.writeln('modified=${modifications.length}');
  stdout.writeln('removed=${removed.length}');
  stdout.writeln(
    'unchanged=${targetManaged.length - additions.length - modifications.length}',
  );
  stdout.writeln('package=${packageFile.path}');
  stdout.writeln('package_bytes=${await packageFile.length()}');
  stdout.writeln('package_sha256=$finalHash');
  stdout.writeln('manifest=${manifestFile.path}');
  stdout.writeln('manifest_sha256=$manifestHash');
}

Map<String, String> _parseArgs(List<String> args) {
  final values = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--') || !arg.contains('=')) {
      throw FormatException('Argumento no válido: $arg');
    }
    final split = arg.indexOf('=');
    final key = arg.substring(2, split);
    final value = arg.substring(split + 1);
    if (key.isEmpty || value.isEmpty || values.containsKey(key)) {
      throw FormatException('Argumento duplicado o vacío: $arg');
    }
    values[key] = value;
  }
  return values;
}

String _required(Map<String, String> options, String key) {
  final value = options[key];
  if (value == null || value.trim().isEmpty) {
    throw FormatException('Falta --$key=<valor>.');
  }
  return value;
}

bool _isWithin(String root, String path) {
  final normalizedRoot = root
      .toLowerCase()
      .replaceAll('/', '\\')
      .replaceAll(RegExp(r'\\+$'), '');
  final normalizedPath = path.toLowerCase().replaceAll('/', '\\');
  return normalizedPath.startsWith('$normalizedRoot\\');
}

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
