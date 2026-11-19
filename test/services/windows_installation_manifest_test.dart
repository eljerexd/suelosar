import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_installation_manifest.dart';

void main() {
  late Directory temporary;
  late Directory install;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('suelosar-manifest-');
    install = Directory('${temporary.path}${Platform.pathSeparator}install');
    await install.create();
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('inventories actual files with relative paths and SHA-256', () async {
    await _write(install, 'suelosar.exe', 'app');
    await _write(install, 'flutter_windows.dll', 'runtime');
    await _write(
      install,
      'data/flutter_assets/assets/maps/soil.pmtiles',
      'tiles',
    );
    await _write(install, 'data/flutter_assets/assets/pdfs/map.pdf', 'pdf');
    await _write(install, 'custom-user-file.txt', 'keep');
    await _write(install, 'unins000.exe', 'setup metadata');

    final service = _service(install, Directory(temporary.path));
    final manifest = await service.createManifest(
      installDirectory: install,
      appVersion: '1.8.1',
      buildNumber: 26,
      renderer: 'maplibre-native',
      installationId: '0123456789abcdef0123456789abcdef0123',
      generatedAt: DateTime.utc(2026, 11, 14),
    );
    final files = manifest['files']! as List<Map<String, Object?>>;
    final byPath = {for (final file in files) file['path']: file};

    expect(manifest['build_number'], 26);
    expect(manifest['platform'], 'windows-x64');
    expect(
      byPath.keys,
      containsAll([
        'suelosar.exe',
        'flutter_windows.dll',
        'data/flutter_assets/assets/maps/soil.pmtiles',
        'data/flutter_assets/assets/pdfs/map.pdf',
        'custom-user-file.txt',
      ]),
    );
    expect(byPath.keys, isNot(contains('unins000.exe')));
    expect(
      byPath['data/flutter_assets/assets/maps/soil.pmtiles']!['classification'],
      'pmtiles',
    );
    expect(
      byPath['data/flutter_assets/assets/pdfs/map.pdf']!['classification'],
      'pdf',
    );
    expect(byPath['custom-user-file.txt']!['managed_by_updater'], isFalse);
    expect(byPath['suelosar.exe']!['managed_by_updater'], isTrue);
    expect(
      byPath['suelosar.exe']!['sha256'],
      'a172cedcae47474b615c54d510a5d84a8dea3032e958587430b413538be3f333',
    );
  });

  test('serializes and reads an atomic schema-valid manifest', () async {
    await _write(install, 'suelosar.exe', 'app');
    final file = File(
      '${temporary.path}${Platform.pathSeparator}baseline.json',
    );
    final manifest = await _service(install, Directory(temporary.path))
        .createManifest(
          installDirectory: install,
          appVersion: '1.8.1',
          buildNumber: 26,
          renderer: 'maplibre-native',
          installationId: '0123456789abcdef0123456789abcdef0123',
          generatedAt: DateTime.utc(2026, 11, 14),
        );

    await file.writeAsString('incomplete previous contents');
    await WindowsInstallationManifestService.writeAtomically(file, manifest);
    final read = await WindowsInstallationManifestService.readManifest(file);

    expect(read, isNotNull);
    expect(read!['build_number'], 26);
    expect(
      (await file.parent.list().toList()).whereType<File>().map((f) => f.path),
      [file.path],
    );
  });

  test('verifies managed installed bytes and ignores unmanaged data', () async {
    await _write(install, 'suelosar.exe', 'app');
    await _write(install, 'custom-user-file.txt', 'user data');
    final manifest = await _service(install, Directory(temporary.path))
        .createManifest(
          installDirectory: install,
          appVersion: '1.8.1',
          buildNumber: 26,
          renderer: 'maplibre-native',
          installationId: '0123456789abcdef0123456789abcdef0123',
          generatedAt: DateTime.utc(2026, 11, 14),
        );

    expect(
      await WindowsInstallationManifestService.verifyManagedInventory(
        installDirectory: install,
        manifest: manifest,
      ),
      isTrue,
    );
    await _write(install, 'custom-user-file.txt', 'changed by user');
    expect(
      await WindowsInstallationManifestService.verifyManagedInventory(
        installDirectory: install,
        manifest: manifest,
      ),
      isTrue,
    );

    await _write(install, 'suelosar.exe', 'tampered app');
    expect(
      await WindowsInstallationManifestService.verifyManagedInventory(
        installDirectory: install,
        manifest: manifest,
      ),
      isFalse,
    );
    await File('${install.path}${Platform.pathSeparator}suelosar.exe').delete();
    expect(
      await WindowsInstallationManifestService.verifyManagedInventory(
        installDirectory: install,
        manifest: manifest,
      ),
      isFalse,
    );
  });

  test('rejects malformed schema and unsafe paths', () async {
    final manifest = _manifest();
    expect(
      WindowsInstallationManifestService.isValidManifest(manifest),
      isTrue,
    );
    final files = manifest['files']! as List<Map<String, dynamic>>;
    files[0]['path'] = '../outside.exe';
    expect(
      WindowsInstallationManifestService.isValidManifest(manifest),
      isFalse,
    );
    files[0]['path'] = 'app.exe';
    files.single['path'] = 'C:/outside.exe';
    expect(
      WindowsInstallationManifestService.isValidManifest(manifest),
      isFalse,
    );
    files.single['path'] = 'app.exe';
    files.single['path'] = 'CON.txt';
    expect(
      WindowsInstallationManifestService.isValidManifest(manifest),
      isFalse,
    );
    files.single['path'] = 'app.exe';
    files.add(Map<String, dynamic>.from(files.single));
    expect(
      WindowsInstallationManifestService.isValidManifest(manifest),
      isFalse,
    );
  });

  test('compares added, modified, removed and unchanged managed files', () {
    final local = _manifest(
      files: [
        _file('same.dll', 'a', 1),
        _file('change.dll', 'b', 1),
        _file('gone.dll', 'c', 1),
        _file('user.txt', 'f', 1, managed: false),
      ],
    );
    final remote = _manifest(
      files: [
        _file('same.dll', 'a', 1),
        _file('change.dll', 'd', 1),
        _file('new.dll', 'e', 1),
        _file('user.txt', 'e', 2, managed: false),
      ],
    );

    final diff = WindowsManifestComparison.compare(local, remote);

    expect(diff.compatible, isTrue);
    expect(diff.unchangedFiles, ['same.dll']);
    expect(diff.modifiedFiles, ['change.dll']);
    expect(diff.removedFiles, ['gone.dll']);
    expect(diff.newFiles, ['new.dll']);
  });

  test(
    'rejects incompatible schemas, renderer baseline and minimum version',
    () {
      final local = _manifest();
      final otherSchema = _manifest()..['schema_version'] = 2;
      expect(
        WindowsManifestComparison.compare(local, otherSchema).compatible,
        isFalse,
      );

      final unsupported = _manifest()
        ..['minimum_supported_baseline'] = '1.8.2+1';
      expect(
        WindowsManifestComparison.compare(local, unsupported).reason,
        'unsupported-baseline',
      );

      final wrongRenderer = _manifest()..['compatibility_id'] = 'other-install';
      expect(
        WindowsManifestComparison.compare(local, wrongRenderer).compatible,
        isFalse,
      );
    },
  );

  test(
    'migration creates the 1.8.1 baseline but leaves unrelated data alone',
    () async {
      await _write(install, 'suelosar.exe', 'app');
      final metadata = Directory(
        '${temporary.path}${Platform.pathSeparator}meta',
      );
      final manifestFile = File(
        '${metadata.path}${Platform.pathSeparator}baseline.json',
      );
      final service = WindowsInstallationManifestService(
        installDirectory: install,
        manifestFile: manifestFile,
        version: '1.8.1+26',
        buildNumber: 26,
        renderer: 'maplibre-native',
        clock: () => DateTime.utc(2026, 11, 14),
      );

      expect(await service.ensureTransitionBaseline(), isTrue);
      expect(await service.ensureTransitionBaseline(), isTrue);
      expect(
        (await WindowsInstallationManifestService.readManifest(
          manifestFile,
        ))!['build_number'],
        26,
      );
      expect(
        await File(
          '${temporary.path}${Platform.pathSeparator}custom-user-file.txt',
        ).exists(),
        isFalse,
      );
    },
  );

  test('full Setup recovery refreshes the installed-version baseline', () async {
    await _write(install, 'suelosar.exe', 'repaired 1.8.2 app');
    final manifestFile = File(
      '${temporary.path}${Platform.pathSeparator}meta${Platform.pathSeparator}baseline.json',
    );
    final transition = WindowsInstallationManifestService(
      installDirectory: install,
      manifestFile: manifestFile,
      version: '1.8.1+26',
      buildNumber: 26,
      renderer: 'maplibre-native',
      clock: () => DateTime.utc(2026, 11, 15),
    );
    await transition.ensureTransitionBaseline();

    final recovered = WindowsInstallationManifestService(
      installDirectory: install,
      manifestFile: manifestFile,
      version: '1.8.2+27',
      buildNumber: 27,
      renderer: 'maplibre-native',
      clock: () => DateTime.utc(2026, 11, 15, 1),
    );

    expect(await recovered.ensureTransitionBaseline(), isTrue);
    final manifest = await WindowsInstallationManifestService.readManifest(
      manifestFile,
    );
    expect(manifest?['app_version'], '1.8.2');
    expect(manifest?['build_number'], 27);
    expect(
      await WindowsInstallationManifestService.verifyManagedInventory(
        installDirectory: install,
        manifest: manifest!,
      ),
      isTrue,
    );
  });
}

WindowsInstallationManifestService _service(
  Directory install,
  Directory metadata,
) => WindowsInstallationManifestService(
  installDirectory: install,
  manifestFile: File('${metadata.path}${Platform.pathSeparator}manifest.json'),
  version: '1.8.1+26',
  buildNumber: 26,
  renderer: 'maplibre-native',
);

Future<void> _write(Directory root, String relative, String content) async {
  final file = File(
    '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Map<String, dynamic> _manifest({List<Map<String, dynamic>>? files}) => {
  'schema_version': 1,
  'app_version': '1.8.1',
  'build_number': 26,
  'platform': 'windows-x64',
  'renderer': 'maplibre-native',
  'compatibility_id': 'suelosar-windows-x64-v1',
  'installation_id': '0123456789abcdef0123456789abcdef0123',
  'generated_at_utc': '2026-11-14T00:00:00.000Z',
  'files': files ?? [_file('app.exe', 'a', 1)],
};

Map<String, dynamic> _file(
  String path,
  String hashChar,
  int size, {
  bool managed = true,
}) => {
  'path': path,
  'size': size,
  'sha256': hashChar * 64,
  'classification': 'native-library',
  'managed_by_updater': managed,
};
