import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_differential_update.dart';
import 'package:suelosar/services/windows_update_models.dart';

void main() {
  group('WindowsDifferentialManifest', () {
    test('rejects unsafe paths and accepts normalized file paths', () {
      expect(isSafeWindowsRelativePath('data/app.so'), isTrue);
      expect(isSafeWindowsRelativePath('C:/Windows/app.dll'), isFalse);
      expect(isSafeWindowsRelativePath('../app.dll'), isFalse);
      expect(isSafeWindowsRelativePath('data/../app.dll'), isFalse);
      expect(isSafeWindowsRelativePath('CON.txt'), isFalse);
      expect(isSafeWindowsRelativePath('data\\app.dll'), isFalse);
    });

    test('supports same-SemVer differential builds only when newer', () {
      final baseline = UpdateVersion.tryParse('1.8.1+23')!;
      final target = UpdateVersion.tryParse('1.8.1+24')!;

      expect(
        WindowsDifferentialManifest.supportsDifferentialTarget(target),
        isTrue,
      );
      expect(
        WindowsDifferentialManifest.isTargetNewerThanBaseline(
          target: target,
          baseline: baseline,
        ),
        isTrue,
      );
      expect(
        WindowsDifferentialManifest.isTargetNewerThanBaseline(
          target: baseline,
          baseline: baseline,
        ),
        isFalse,
      );
      expect(
        WindowsDifferentialManifest.isTargetNewerThanBaseline(
          target: UpdateVersion.tryParse('1.8.1+22')!,
          baseline: baseline,
        ),
        isFalse,
      );
      expect(
        WindowsDifferentialManifest.supportsDifferentialTarget(
          UpdateVersion.tryParse('1.8.0+99'),
        ),
        isFalse,
      );
      expect(
        WindowsDifferentialManifest.supportsDifferentialTarget(
          UpdateVersion.tryParse('1.8.1'),
        ),
        isFalse,
      );
      expect(
        WindowsDifferentialManifest.supportsDifferentialTarget(
          UpdateVersion.tryParse('1.8.1-rc.1+24'),
        ),
        isFalse,
      );
    });
    test('parses exact stable version, build and package identity', () {
      final manifest = _manifest();
      final parsed = WindowsDifferentialManifest.tryParse(
        manifest,
        expectedVersion: '1.8.2+27',
        expectedRenderer: 'maplibre-native',
        expectedCompatibilityId: 'suelosar-windows-x64-v1',
      );

      expect(parsed, isNotNull);
      expect(parsed!.version.toString(), '1.8.2+27');
      expect(parsed.minimumSupportedBaseline.toString(), '1.8.1+26');
      expect(
        parsed.package.name,
        'SuelosAR-Differential-1.8.2+27-win-x64-maplibre-native.zip',
      );
      final roundTrip = WindowsDifferentialManifest.tryParse(
        parsed.toJson(),
        expectedVersion: '1.8.2+27',
        expectedRenderer: 'maplibre-native',
        expectedCompatibilityId: 'suelosar-windows-x64-v1',
      );
      expect(roundTrip, isNotNull);
      expect((parsed.toJson()['modified_files']! as List).cast<String>(), [
        'suelosar.exe',
      ]);
      expect(
        WindowsDifferentialManifest.tryParse(
          manifest,
          expectedVersion: '1.8.2+28',
          expectedRenderer: 'maplibre-native',
          expectedCompatibilityId: 'suelosar-windows-x64-v1',
        ),
        isNull,
      );
    });

    test('accepts a higher build within the same semantic version', () {
      final manifest = _manifest()
        ..['version'] = '1.8.1+24'
        ..['app_version'] = '1.8.1'
        ..['build_number'] = 24
        ..['minimum_supported_baseline'] = '1.8.1+23';
      (manifest['package']! as Map<String, dynamic>)['name'] =
          'SuelosAR-Differential-1.8.1+24-win-x64-maplibre-native.zip';

      final parsed = WindowsDifferentialManifest.tryParse(
        manifest,
        expectedVersion: '1.8.1+24',
        expectedRenderer: 'maplibre-native',
        expectedCompatibilityId: 'suelosar-windows-x64-v1',
      );

      expect(parsed, isNotNull);
      expect(parsed!.version.toString(), '1.8.1+24');
      expect(parsed.minimumSupportedBaseline.toString(), '1.8.1+23');

      for (final invalidBaseline in ['1.8.1+24', '1.8.1+25']) {
        final invalid = Map<String, dynamic>.from(manifest)
          ..['minimum_supported_baseline'] = invalidBaseline;
        expect(
          WindowsDifferentialManifest.tryParse(
            invalid,
            expectedVersion: '1.8.1+24',
            expectedRenderer: 'maplibre-native',
            expectedCompatibilityId: 'suelosar-windows-x64-v1',
          ),
          isNull,
        );
      }
    });
    test('rejects expanded package inventories above the safe limit', () {
      final oversized = {
        'path': 'large.bin',
        'size': WindowsDifferentialManifest.maximumPackageBytes + 1,
        'sha256': List.filled(64, 'a').join(),
        'classification': 'application-resource',
        'managed_by_updater': true,
        'change_type': 'added',
      };
      final manifest = _manifest(files: [oversized], packageFiles: [oversized]);
      expect(
        WindowsDifferentialManifest.tryParse(
          manifest,
          expectedVersion: '1.8.2+27',
          expectedRenderer: 'maplibre-native',
          expectedCompatibilityId: 'suelosar-windows-x64-v1',
        ),
        isNull,
      );
    });
  });

  test(
    'stages exact changed inventory and preserves unmanaged files',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'suelosar-differential-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final oldExe = utf8.encode('old executable');
      final newExe = utf8.encode('new executable');
      final newAsset = utf8.encode('new resource');
      final userData = utf8.encode('user data');
      final obsoleteDll = utf8.encode('obsolete');
      final local = _localManifest({
        'suelosar.exe': _entry('suelosar.exe', oldExe, 'executable'),
        'obsolete.dll': _entry('obsolete.dll', obsoleteDll, 'native-library'),
        'settings.json': _entry(
          'settings.json',
          userData,
          'unmanaged',
          managed: false,
        ),
      });
      final remoteFiles = [
        _entry('suelosar.exe', newExe, 'executable'),
        _entry('data/new.txt', newAsset, 'application-resource'),
      ];
      final zip = Archive()
        ..addFile(ArchiveFile('suelosar.exe', newExe.length, newExe))
        ..addFile(ArchiveFile('data/new.txt', newAsset.length, newAsset));
      final zipBytes = ZipEncoder().encode(zip);
      final packageFile = File('${temporary.path}/payload.zip');
      await packageFile.writeAsBytes(zipBytes, flush: true);
      final localManifestFile = File('${temporary.path}/local.json');
      await localManifestFile.writeAsString(jsonEncode(local), flush: true);
      final installDirectory = Directory('${temporary.path}/install')
        ..createSync();
      await File('${installDirectory.path}/suelosar.exe').writeAsBytes(oldExe);
      await File('${installDirectory.path}/obsolete.dll')
          .writeAsBytes(obsoleteDll);
      await File('${installDirectory.path}/settings.json')
          .writeAsBytes(userData);
      final updateDirectory = Directory('${temporary.path}/update')
        ..createSync();
      final remoteJson = _manifest(
        files: remoteFiles,
        packageFiles: remoteFiles,
        removed: ['obsolete.dll'],
        packageHash: sha256.convert(zipBytes).toString(),
        packageSize: zipBytes.length,
      );
      final remote = WindowsDifferentialManifest.tryParse(
        remoteJson,
        expectedVersion: '1.8.2+27',
        expectedRenderer: 'maplibre-native',
        expectedCompatibilityId: 'suelosar-windows-x64-v1',
      )!;

      final prepared = await WindowsDifferentialPackageStager.stage(
        packageFile: packageFile,
        remote: remote,
        localManifest: local,
        localManifestFile: localManifestFile,
        installDirectory: installDirectory,
        updateDirectory: updateDirectory,
      );

      expect(
        await File('${prepared.stagingDirectory.path}/suelosar.exe')
            .readAsBytes(),
        newExe,
      );
      expect(
        await File('${prepared.stagingDirectory.path}/data/new.txt')
            .readAsBytes(),
        newAsset,
      );
      expect(await prepared.applyList.readAsString(), contains('suelosar.exe'));
      expect(await prepared.removeList.readAsString(), 'obsolete.dll\n');
      expect(prepared.applyListSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      final targetManifest = jsonDecode(
        await prepared.targetManifest.readAsString(),
      ) as Map<String, dynamic>;
      expect(targetManifest['installation_id'], local['installation_id']);
      expect(
        (targetManifest['files'] as List).cast<Map<String, dynamic>>().any(
          (file) =>
              file['path'] == 'settings.json' &&
              file['managed_by_updater'] == false,
        ),
        isTrue,
      );
    },
  );

  test('rejects a package hash mismatch before staging', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'suelosar-differential-package-hash-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final oldExe = utf8.encode('old executable');
    final newExe = utf8.encode('new executable');
    final local = _localManifest({
      'suelosar.exe': _entry('suelosar.exe', oldExe, 'executable'),
    });
    final remoteFiles = [_entry('suelosar.exe', newExe, 'executable')];
    final zip = Archive()
      ..addFile(ArchiveFile('suelosar.exe', newExe.length, newExe));
    final zipBytes = ZipEncoder().encode(zip);
    final packageFile = File('${temporary.path}/payload.zip');
    await packageFile.writeAsBytes(zipBytes, flush: true);
    final localManifestFile = File('${temporary.path}/local.json');
    await localManifestFile.writeAsString(jsonEncode(local), flush: true);
    final installDirectory = Directory('${temporary.path}/install')
      ..createSync();
    await File('${installDirectory.path}/suelosar.exe').writeAsBytes(oldExe);
    final updateDirectory = Directory('${temporary.path}/update')..createSync();
    final remote = WindowsDifferentialManifest.tryParse(
      _manifest(
        files: remoteFiles,
        packageFiles: remoteFiles,
        packageHash: List.filled(64, 'f').join(),
        packageSize: zipBytes.length,
      ),
      expectedVersion: '1.8.2+27',
      expectedRenderer: 'maplibre-native',
      expectedCompatibilityId: 'suelosar-windows-x64-v1',
    )!;

    await expectLater(
      WindowsDifferentialPackageStager.stage(
        packageFile: packageFile,
        remote: remote,
        localManifest: local,
        localManifestFile: localManifestFile,
        installDirectory: installDirectory,
        updateDirectory: updateDirectory,
      ),
      throwsFormatException,
    );
    expect(Directory('${updateDirectory.path}/staged').existsSync(), isFalse);
  });
  test('rejects a package size mismatch before staging', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'suelosar-differential-package-size-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final oldExe = utf8.encode('old executable');
    final newExe = utf8.encode('new executable');
    final local = _localManifest({
      'suelosar.exe': _entry('suelosar.exe', oldExe, 'executable'),
    });
    final remoteFiles = [_entry('suelosar.exe', newExe, 'executable')];
    final zip = Archive()
      ..addFile(ArchiveFile('suelosar.exe', newExe.length, newExe));
    final zipBytes = ZipEncoder().encode(zip);
    final packageFile = File('${temporary.path}/payload.zip');
    await packageFile.writeAsBytes(zipBytes, flush: true);
    final localManifestFile = File('${temporary.path}/local.json');
    await localManifestFile.writeAsString(jsonEncode(local), flush: true);
    final installDirectory = Directory('${temporary.path}/install')
      ..createSync();
    await File('${installDirectory.path}/suelosar.exe').writeAsBytes(oldExe);
    final updateDirectory = Directory('${temporary.path}/update')..createSync();
    final remote = WindowsDifferentialManifest.tryParse(
      _manifest(
        files: remoteFiles,
        packageFiles: remoteFiles,
        packageHash: sha256.convert(zipBytes).toString(),
        packageSize: zipBytes.length + 1,
      ),
      expectedVersion: '1.8.2+27',
      expectedRenderer: 'maplibre-native',
      expectedCompatibilityId: 'suelosar-windows-x64-v1',
    )!;

    await expectLater(
      WindowsDifferentialPackageStager.stage(
        packageFile: packageFile,
        remote: remote,
        localManifest: local,
        localManifestFile: localManifestFile,
        installDirectory: installDirectory,
        updateDirectory: updateDirectory,
      ),
      throwsFormatException,
    );
    expect(Directory('${updateDirectory.path}/staged').existsSync(), isFalse);
  });
  test('removes partial staging after a file hash mismatch', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'suelosar-differential-invalid-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final oldExe = utf8.encode('old executable');
    final expectedExe = utf8.encode('expected executable');
    final wrongExe = utf8.encode('different executable');
    final local = _localManifest({
      'suelosar.exe': _entry('suelosar.exe', oldExe, 'executable'),
    });
    final remoteFiles = [_entry('suelosar.exe', expectedExe, 'executable')];
    final zip = Archive()
      ..addFile(ArchiveFile('suelosar.exe', wrongExe.length, wrongExe));
    final zipBytes = ZipEncoder().encode(zip);
    final packageFile = File('${temporary.path}/payload.zip');
    await packageFile.writeAsBytes(zipBytes, flush: true);
    final localManifestFile = File('${temporary.path}/local.json');
    await localManifestFile.writeAsString(jsonEncode(local), flush: true);
    final installDirectory = Directory('${temporary.path}/install')
      ..createSync();
    await File('${installDirectory.path}/suelosar.exe').writeAsBytes(oldExe);
    final updateDirectory = Directory('${temporary.path}/update')..createSync();
    final remote = WindowsDifferentialManifest.tryParse(
      _manifest(
        files: remoteFiles,
        packageFiles: remoteFiles,
        packageHash: sha256.convert(zipBytes).toString(),
        packageSize: zipBytes.length,
      ),
      expectedVersion: '1.8.2+27',
      expectedRenderer: 'maplibre-native',
      expectedCompatibilityId: 'suelosar-windows-x64-v1',
    )!;

    await expectLater(
      WindowsDifferentialPackageStager.stage(
        packageFile: packageFile,
        remote: remote,
        localManifest: local,
        localManifestFile: localManifestFile,
        installDirectory: installDirectory,
        updateDirectory: updateDirectory,
      ),
      throwsFormatException,
    );
    expect(Directory('${updateDirectory.path}/staged').existsSync(), isFalse);
  });
}

Map<String, dynamic> _manifest({
  List<Map<String, Object?>>? files,
  List<Map<String, Object?>>? packageFiles,
  List<String> removed = const [],
  String? packageHash,
  int packageSize = 1,
}) {
  final targetFiles =
      files ??
      [_entry('suelosar.exe', utf8.encode('new executable'), 'executable')];
  final changedFiles = packageFiles ?? targetFiles;
  return {
    'schema_version': 1,
    'version': '1.8.2+27',
    'app_version': '1.8.2',
    'build_number': 27,
    'required_installation_schema': 1,
    'minimum_supported_baseline': '1.8.1+26',
    'platform': 'windows-x64',
    'architecture': 'x64',
    'renderer': 'maplibre-native',
    'compatibility_id': 'suelosar-windows-x64-v1',
    'package': {
      'name': 'SuelosAR-Differential-1.8.2+27-win-x64-maplibre-native.zip',
      'size': packageSize,
      'sha256': packageHash ?? List.filled(64, '0').join(),
      'files': changedFiles.map((file) {
        final changed = Map<String, Object?>.from(file);
        changed['change_type'] ??= changed['path'] == 'suelosar.exe'
            ? 'modified'
            : 'added';
        return changed;
      }).toList(),
    },
    'files': targetFiles,
    'added_files': changedFiles
        .where((file) => file['path'] != 'suelosar.exe')
        .map((file) => file['path'])
        .toList(),
    'modified_files': changedFiles
        .where((file) => file['path'] == 'suelosar.exe')
        .map((file) => file['path'])
        .toList(),
    'removed_files': removed,
  };
}

Map<String, dynamic> _localManifest(Map<String, Map<String, Object?>> files) =>
    {
      'schema_version': 1,
      'app_version': '1.8.1',
      'build_number': 26,
      'platform': 'windows-x64',
      'renderer': 'maplibre-native',
      'compatibility_id': 'suelosar-windows-x64-v1',
      'installation_id': '00000000-0000-4000-8000-000000000001',
      'generated_at_utc': '2026-11-15T00:00:00.000Z',
      'files': files.values.toList(),
    };

Map<String, Object?> _entry(
  String path,
  List<int> bytes,
  String classification, {
  bool managed = true,
}) => {
  'path': path,
  'size': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'classification': classification,
  'managed_by_updater': managed,
};
