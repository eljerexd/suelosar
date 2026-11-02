import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:suelosar/services/windows_update_service.dart';

void main() {
  group('SemanticVersion precedence', () {
    final cases = <(String, String, int)>[
      ('1.7.0', '1.7.1', -1),
      ('1.7.1', '1.7.2', -1),
      ('1.7.2', '1.8.0', -1),
      ('1.8.0', '2.0.0', -1),
      ('1.7.0', '1.7.0', 0),
      ('1.7.0', '1.6.9', 1),
      ('v1.7.0+20', '1.7.0', 0),
      ('1.7.0-rc.1', '1.7.0', -1),
    ];
    for (final (installed, remote, expected) in cases) {
      test('$installed compared with $remote', () {
        final left = SemanticVersion.tryParse(installed)!;
        final right = SemanticVersion.tryParse(remote)!;
        expect(left.compareTo(right).sign, expected);
      });
    }

    test('rejects malformed versions and numeric prerelease leading zeros', () {
      expect(SemanticVersion.tryParse('01.7.0'), isNull);
      expect(SemanticVersion.tryParse('1.7.0-rc.01'), isNull);
      expect(SemanticVersion.tryParse('1.7'), isNull);
    });
  });

  group('WindowsUpdateService', () {
    test(
      'Inno output name and updater selector share the pubspec version',
      () async {
        final pubspec = await File('pubspec.yaml').readAsString();
        final setup = await File('SetupSuelosAR.iss').readAsString();
        final version = RegExp(
          r'^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$',
          multiLine: true,
        ).firstMatch(pubspec)!.group(1)!;
        final expectedName = 'SuelosAR-Setup-$version.exe';

        expect(setup, contains('GetEnv("SUELOSAR_VERSION")'));
        expect(
          setup,
          contains('OutputBaseFilename=SuelosAR-Setup-{#MyAppVersion}'),
        );
        expect(
          setup,
          contains('AppId={{C7098677-ADDE-4FE4-A0FA-E24AC63B3CD0}'),
        );
        expect(setup, contains('CloseApplications=yes'));
        expect(setup, contains('Flags: nowait postinstall skipifsilent'));
        expect(setup, isNot(contains('RestartApplications=')));
        expect(
          setup,
          contains('#define ProjectDir RemoveBackslashUnlessRoot(SourcePath)'),
        );
        expect(
          setup,
          contains(
            r'#define BuildDir ProjectDir + "\build\windows\x64\runner\Release"',
          ),
        );
        expect(
          setup,
          contains(
            r'#define InstallerResourcesDir ProjectDir + "\windows\runner\resources"',
          ),
        );
        expect(
          setup,
          contains(
            r'#define InstallerOutputDir ProjectDir + "\artifacts\windows-installer"',
          ),
        );
        expect(
          setup,
          contains('SetupIconFile={#InstallerResourcesDir}\\app_icon.ico'),
        );
        expect(setup, contains('OutputDir={#InstallerOutputDir}'));
        expect(setup, contains('Flutter Windows Release directory is missing'));
        expect(
          setup,
          contains('Flutter Windows Release executable is missing'),
        );
        expect(setup, contains('Installer icon is missing'));

        final serviceImplementation = await File(
          'lib/services/windows_update_service_io.dart',
        ).readAsString();
        expect(
          serviceImplementation,
          contains('_issuedDownloadChecks.remove(check)'),
        );
        expect(
          serviceImplementation,
          contains('_installerLifecycleValidated = false'),
        );

        final buildScript = await File(
          'tool/build_windows_installer.ps1',
        ).readAsString();
        expect(buildScript, contains(r"Join-Path $PSScriptRoot '..'"));
        expect(buildScript, contains("'build\\windows\\x64\\runner\\Release'"));
        expect(
          buildScript,
          contains("'windows\\runner\\resources\\app_icon.ico'"),
        );
        expect(buildScript, contains("'artifacts\\windows-installer'"));
        expect(buildScript, contains('Required installer input is missing'));
        expect(
          buildScript,
          contains(
            r"(?<version>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+\d+",
          ),
        );

        final digest = List.filled(64, 'c').join();
        final service = _service(
          installed: '1.6.9',
          release: _releaseJson(
            tag: 'v$version',
            assets: [
              _installerAsset(version: version, digest: 'sha256:$digest'),
            ],
          ),
        );
        final result = await service.checkForUpdates();

        expect(result.status, WindowsUpdateStatus.updateAvailable);
        expect(result.installer!.name, expectedName);
        service.close();
      },
    );

    test('unsupported platform is reported without an HTTP request', () async {
      final service = WindowsUpdateService(
        client: MockClient((_) async => fail('unexpected request')),
        isWindows: false,
      );
      final result = await service.checkForUpdates();
      expect(result.status, WindowsUpdateStatus.unsupportedPlatform);
      service.close();
    });

    test('detects a newer patch release and ignores build number', () async {
      final service = _service(
        release: _releaseJson(tag: 'v1.7.1', assets: const []),
        installed: '1.7.0+20',
      );
      final result = await service.checkForUpdates();
      expect(result.status, WindowsUpdateStatus.installerAssetMissing);
      expect(result.updateAvailable, isTrue);
      expect(result.installedVersion.toString(), '1.7.0+20');
      expect(result.release!.version.toString(), '1.7.1');
      service.close();
    });

    test(
      'detects newer minor and major releases even without an installer',
      () async {
        for (final tag in ['v1.8.0', 'v2.0.0']) {
          final service = _service(
            release: _releaseJson(tag: tag, assets: const []),
            installed: '1.7.0',
          );
          final result = await service.checkForUpdates();
          expect(result.updateAvailable, isTrue, reason: tag);
          expect(result.status, WindowsUpdateStatus.installerAssetMissing);
          service.close();
        }
      },
    );

    test('does not offer a release equal to or older than installed', () async {
      for (final remote in ['v1.7.0', 'v1.6.9']) {
        final service = _service(
          release: _releaseJson(tag: remote, assets: const []),
          installed: '1.7.0',
        );
        expect(
          (await service.checkForUpdates()).status,
          WindowsUpdateStatus.upToDate,
        );
        service.close();
      }
    });

    test(
      'rejects a prerelease and identifies missing installer assets',
      () async {
        final prerelease = _service(
          release: _releaseJson(tag: 'v1.8.0-rc.1', assets: const []),
        );
        expect(
          (await prerelease.checkForUpdates()).status,
          WindowsUpdateStatus.noStableRelease,
        );
        prerelease.close();

        final missing = _service(
          release: _releaseJson(tag: 'v1.8.0', assets: const []),
        );
        expect(
          (await missing.checkForUpdates()).status,
          WindowsUpdateStatus.installerAssetMissing,
        );
        missing.close();
      },
    );

    test(
      'accepts only a release-matched installer with a SHA-256 digest',
      () async {
        final digest = List.filled(64, 'a').join();
        final asset = _installerAsset(digest: 'sha256:$digest');
        final service = _service(
          release: _releaseJson(tag: 'v1.8.0', assets: [asset]),
        );
        final result = await service.checkForUpdates();
        expect(result.status, WindowsUpdateStatus.updateAvailable);
        expect(result.canDownload, isTrue);
        expect(result.sha256, digest);
        service.close();
      },
    );

    test(
      'uses an exact-name SHA-256 sidecar when asset digest is unavailable',
      () async {
        final digest = List.filled(64, 'b').join();
        final installer = _installerAsset();
        final sidecar = {
          'id': 2,
          'name': 'SuelosAR-Setup-1.8.0.exe.sha256',
          'size': 82,
          'digest': null,
          'browser_download_url':
              'https://github.com/eljerexd/suelosar/releases/download/v1.8.0/SuelosAR-Setup-1.8.0.exe.sha256',
        };
        final service = WindowsUpdateService(
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          client: MockClient((request) async {
            if (request.url.toString() ==
                WindowsUpdateService.latestReleaseUrl) {
              return http.Response(
                jsonEncode(
                  _releaseJson(tag: 'v1.8.0', assets: [installer, sidecar]),
                ),
                200,
              );
            }
            return http.Response('$digest  SuelosAR-Setup-1.8.0.exe', 200);
          }),
        );
        final result = await service.checkForUpdates();
        expect(result.status, WindowsUpdateStatus.updateAvailable);
        expect(result.sha256, digest);
        service.close();
      },
    );

    test(
      'keeps a newer update unavailable for download without checksum',
      () async {
        final service = _service(
          release: _releaseJson(tag: 'v1.8.0', assets: [_installerAsset()]),
        );
        final result = await service.checkForUpdates();
        expect(result.updateAvailable, isTrue);
        expect(result.status, WindowsUpdateStatus.checksumUnavailable);
        expect(result.canDownload, isFalse);
        service.close();
      },
    );

    test(
      'rejects a download check not issued by this service instance',
      () async {
        final service = WindowsUpdateService(
          client: MockClient(
            (_) async => fail('forged check must not download'),
          ),
          isWindows: true,
        );
        final forged = WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.updateAvailable,
          installedVersion: SemanticVersion.tryParse('1.7.0'),
          release: _releaseInfo(),
          installer: WindowsReleaseAsset(
            name: 'SuelosAR-Setup-1.8.0.exe',
            downloadUrl: Uri.parse(
              'https://github.com/eljerexd/suelosar/releases/download/v1.8.0/SuelosAR-Setup-1.8.0.exe',
            ),
            size: 128,
          ),
          sha256: List.filled(64, 'a').join(),
        );

        final result = await service.downloadUpdate(forged);

        expect(result.error!.code, WindowsUpdateErrorCode.installerNotVerified);
        service.close();
      },
    );

    test(
      'reports malformed GitHub JSON as structured invalid metadata',
      () async {
        final service = WindowsUpdateService(
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          client: MockClient((_) async => http.Response('{broken', 200)),
        );
        final result = await service.checkForUpdates();
        expect(result.status, WindowsUpdateStatus.invalidRelease);
        expect(result.error!.code, WindowsUpdateErrorCode.invalidJson);
        service.close();
      },
    );

    test(
      'rejects an installer URL that does not match its release tag',
      () async {
        final asset = _installerAsset(
          url:
              'https://github.com/eljerexd/suelosar/releases/download/v1.7.9/SuelosAR-Setup.exe',
          digest: 'sha256:${List.filled(64, 'a').join()}',
        );
        final service = _service(
          release: _releaseJson(tag: 'v1.8.0', assets: [asset]),
        );
        final result = await service.checkForUpdates();
        expect(result.status, WindowsUpdateStatus.failed);
        expect(result.error!.code, WindowsUpdateErrorCode.invalidRelease);
        service.close();
      },
    );

    test(
      'rejects installer filenames that do not match the Inno output version',
      () async {
        final asset = Map<String, Object?>.from(_installerAsset())
          ..['name'] = 'SuelosAR-Setup-1.7.9.exe'
          ..['browser_download_url'] =
              'https://github.com/eljerexd/suelosar/releases/download/v1.8.0/SuelosAR-Setup-1.7.9.exe';
        final service = _service(
          release: _releaseJson(tag: 'v1.8.0', assets: [asset]),
        );
        final result = await service.checkForUpdates();
        expect(result.updateAvailable, isTrue);
        expect(result.status, WindowsUpdateStatus.installerAssetMissing);
        expect(result.canDownload, isFalse);
        service.close();
      },
    );

    test(
      'streams progress and verifies SHA-256 before returning installer',
      () async {
        final bytes = utf8.encode('test installer bytes');
        final digest = sha256.convert(bytes).toString();
        final root = await Directory.systemTemp.createTemp('update-test-');
        final asset = Map<String, Object?>.from(
          _installerAsset(digest: 'sha256:$digest'),
        )..['size'] = bytes.length;
        final release = _releaseJson(tag: 'v1.8.0', assets: [asset]);
        final service = WindowsUpdateService(
          client: MockClient((request) async {
            if (request.url.toString() ==
                WindowsUpdateService.latestReleaseUrl) {
              return http.Response(jsonEncode(release), 200);
            }
            expect(request.url.host, 'github.com');
            return http.Response.bytes(
              bytes,
              200,
              headers: {'content-length': '${bytes.length}'},
            );
          }),
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          temporaryDirectory: root,
        );
        final check = await service.checkForUpdates();
        expect(check.canDownload, isTrue);
        final progress = <WindowsUpdateProgress>[];
        final result = await service.downloadUpdate(
          check,
          onProgress: progress.add,
        );
        expect(
          result.status,
          WindowsUpdateOperationStatus.succeeded,
          reason: result.error?.message,
        );
        expect(await File(result.installerPath!).readAsBytes(), bytes);
        expect(progress, isNotEmpty);
        expect(progress.last.downloadedBytes, bytes.length);
        expect(result.sha256, digest);
        await root.delete(recursive: true);
        service.close();
      },
    );

    test('cancellation removes the partial download', () async {
      final root = await Directory.systemTemp.createTemp('update-cancel-');
      final digest = List.filled(64, 'a').join();
      final asset = Map<String, Object?>.from(
        _installerAsset(digest: 'sha256:$digest'),
      )..['size'] = 10;
      final client = _CancelClient(
        _releaseJson(tag: 'v1.8.0', assets: [asset]),
      );
      final service = WindowsUpdateService(
        client: client,
        isWindows: true,
        installedVersionReader: () async => '1.7.0',
        temporaryDirectory: root,
      );
      final check = await service.checkForUpdates();
      expect(check.canDownload, isTrue);
      final resultFuture = service.downloadUpdate(
        check,
        onProgress: (_) => service.cancelDownload(),
      );
      final result = await resultFuture;
      expect(
        result.status,
        WindowsUpdateOperationStatus.cancelled,
        reason: result.error?.message,
      );
      expect(await root.list().toList(), isEmpty);
      await root.delete(recursive: true);
      service.close();
    });

    test(
      'verification refuses and preserves an installer not owned by service',
      () async {
        final root = await Directory.systemTemp.createTemp('update-hash-');
        final file = File('${root.path}${Platform.pathSeparator}bad.exe');
        await file.writeAsString('invalid');
        final service = WindowsUpdateService(
          client: MockClient((_) async => http.Response('', 200)),
          isWindows: true,
          temporaryDirectory: root,
        );
        final result = await service.verifyDownloadedInstaller(
          file.path,
          List.filled(64, '0').join(),
        );
        expect(result.error!.code, WindowsUpdateErrorCode.installerNotVerified);
        expect(await file.exists(), isTrue);
        await root.delete(recursive: true);
        service.close();
      },
    );

    test(
      'keeps installer launch blocked until Windows lifecycle validation',
      () async {
        final bytes = utf8.encode('MZ verified placeholder');
        final digest = sha256.convert(bytes).toString();
        final root = await Directory.systemTemp.createTemp('update-launch-');
        final asset = Map<String, Object?>.from(
          _installerAsset(digest: 'sha256:$digest'),
        )..['size'] = bytes.length;
        final release = _releaseJson(tag: 'v1.8.0', assets: [asset]);
        String? startedPath;
        final service = WindowsUpdateService(
          client: MockClient((request) async {
            if (request.url.toString() ==
                WindowsUpdateService.latestReleaseUrl) {
              return http.Response(jsonEncode(release), 200);
            }
            return http.Response.bytes(bytes, 200);
          }),
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          temporaryDirectory: root,
          installerStarter: (path) async => startedPath = path,
        );
        final check = await service.checkForUpdates();
        expect(check.canDownload, isTrue);
        final unverified = await service.launchInstaller(
          '${root.path}${Platform.pathSeparator}unverified.exe',
        );
        expect(
          unverified.error!.code,
          WindowsUpdateErrorCode.installerLifecycleUnavailable,
        );
        final downloaded = await service.downloadUpdate(check);
        expect(downloaded.status, WindowsUpdateOperationStatus.succeeded);
        expect(
          (await service.verifyDownloadedInstaller(
            downloaded.installerPath!,
            digest,
          )).succeeded,
          isTrue,
        );
        final result = await service.launchInstaller(downloaded.installerPath!);
        expect(
          result.status,
          WindowsUpdateOperationStatus.lifecycleUnavailable,
        );
        expect(
          result.error!.code,
          WindowsUpdateErrorCode.installerLifecycleUnavailable,
        );
        expect(startedPath, isNull);
        await root.delete(recursive: true);
        service.close();
      },
    );

    test('maps HTTP failures into structured results', () async {
      final service = WindowsUpdateService(
        client: MockClient((_) async => http.Response('oops', 500)),
        isWindows: true,
        installedVersionReader: () async => '1.7.0',
      );
      final result = await service.checkForUpdates();
      expect(result.status, WindowsUpdateStatus.releaseUnavailable);
      expect(result.error!.code, WindowsUpdateErrorCode.httpError);
      service.close();
    });

    test(
      'checksum mismatch rejects and removes the partial download',
      () async {
        final bytes = utf8.encode('tampered installer');
        final expectedDigest = sha256
            .convert(utf8.encode('expected'))
            .toString();
        final root = await Directory.systemTemp.createTemp('update-bad-hash-');
        final asset = Map<String, Object?>.from(
          _installerAsset(digest: 'sha256:$expectedDigest'),
        )..['size'] = bytes.length;
        final release = _releaseJson(tag: 'v1.8.0', assets: [asset]);
        final service = WindowsUpdateService(
          client: MockClient((request) async {
            if (request.url.toString() ==
                WindowsUpdateService.latestReleaseUrl) {
              return http.Response(jsonEncode(release), 200);
            }
            return http.Response.bytes(bytes, 200);
          }),
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          temporaryDirectory: root,
        );
        final check = await service.checkForUpdates();
        expect(check.canDownload, isTrue);
        final result = await service.downloadUpdate(check);
        expect(
          result.error!.code,
          WindowsUpdateErrorCode.checksumMismatch,
          reason: result.error?.message,
        );
        expect(await root.list().toList(), isEmpty);
        await root.delete(recursive: true);
        service.close();
      },
    );
  });
}

WindowsUpdateService _service({
  required Map<String, Object?> release,
  String installed = '1.7.0',
}) => WindowsUpdateService(
  client: MockClient((request) async {
    expect(request.url.toString(), WindowsUpdateService.latestReleaseUrl);
    return http.Response(jsonEncode(release), 200);
  }),
  isWindows: true,
  installedVersionReader: () async => installed,
);

Map<String, Object?> _releaseJson({
  required String tag,
  required List<Map<String, Object?>> assets,
}) => {
  'tag_name': tag,
  'name': tag,
  'body': 'Release notes',
  'draft': false,
  'prerelease': false,
  'published_at': '2026-11-01T12:00:00Z',
  'html_url': 'https://github.com/eljerexd/suelosar/releases/tag/$tag',
  'assets': assets,
};

Map<String, Object?> _installerAsset({
  String version = '1.8.0',
  String? digest,
  String? url,
}) => {
  'id': 1,
  'name': 'SuelosAR-Setup-$version.exe',
  'size': 128,
  'digest': digest,
  'browser_download_url':
      url ??
      'https://github.com/eljerexd/suelosar/releases/download/v$version/SuelosAR-Setup-$version.exe',
};

WindowsReleaseInfo _releaseInfo() => WindowsReleaseInfo(
  tag: 'v1.8.0',
  version: SemanticVersion.tryParse('1.8.0')!,
  name: 'v1.8.0',
  description: '',
  publishedAt: DateTime.utc(2026),
  assets: const [],
  htmlUrl: Uri.parse(
    'https://github.com/eljerexd/suelosar/releases/tag/v1.8.0',
  ),
);

class _CancelClient extends http.BaseClient {
  _CancelClient(this.release);

  final Map<String, Object?> release;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.toString() == WindowsUpdateService.latestReleaseUrl) {
      final bytes = utf8.encode(jsonEncode(release));
      return http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
        request: request,
      );
    }
    final controller = StreamController<List<int>>();
    if (request is http.AbortableRequest) {
      request.abortTrigger?.then((_) async {
        controller.addError(http.ClientException('aborted'));
        await controller.close();
      });
    }
    scheduleMicrotask(() => controller.add([1, 2, 3]));
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: 10,
      request: request,
    );
  }
}
