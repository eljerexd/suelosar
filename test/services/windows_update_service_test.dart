import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhttp/rhttp.dart' show RedirectSettings, RootCertSource;
import 'package:suelosar/services/windows_update_service.dart';
import 'package:suelosar/services/windows_update_http_client.dart';

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

    test(
      'display strings hide build metadata without changing parsed versions',
      () {
        final cases = <(String, String)>[
          ('1.7.0+20', '1.7.0'),
          ('1.7.0+21', '1.7.0'),
          ('1.8.0+25', '1.8.0'),
        ];
        for (final (raw, displayed) in cases) {
          final version = SemanticVersion.tryParse(raw)!;
          expect(formatWindowsUpdateVersion(raw), displayed);
          expect(version.toString(), raw);
        }
      },
    );
  });

  group('WindowsUpdateService', () {
    test(
      'compares installed build metadata against stable GitHub tags',
      () async {
        final cases = <(String, String, bool)>[
          ('1.7.0+20', 'v1.7.0', false),
          ('1.7.0', 'v1.7.0', false),
          ('1.6.0+10', 'v1.7.0', true),
          ('1.7.0+20', 'v1.7.1', true),
          ('1.8.0+25', 'v1.7.0', false),
        ];

        for (final (installed, tag, updateAvailable) in cases) {
          final service = _service(
            installed: installed,
            release: _releaseJson(tag: tag, assets: const []),
          );
          addTearDown(service.close);

          final result = await service.checkForUpdates();

          expect(
            result.updateAvailable,
            updateAvailable,
            reason: 'installed=$installed, GitHub=$tag',
          );
          expect(
            result.status,
            updateAvailable
                ? WindowsUpdateStatus.installerAssetMissing
                : WindowsUpdateStatus.upToDate,
            reason: 'installed=$installed, GitHub=$tag',
          );
          expect(result.installedVersion.toString(), installed);
          expect(result.release!.tag, tag);
        }
      },
    );

    test(
      'revalidates GitHub notes and accepts a changed body for the same tag',
      () async {
        var body = 'Notas antiguas: paa comodidad.';
        final service = WindowsUpdateService(
          client: MockClient((request) async {
            expect(
              request.url.toString(),
              WindowsUpdateService.latestReleaseUrl,
            );
            expect(request.headers['cache-control'], 'no-cache');
            expect(request.headers.containsKey('if-none-match'), isFalse);
            return http.Response(
              jsonEncode(
                _releaseJson(tag: 'v1.7.0', assets: const [], body: body),
              ),
              200,
            );
          }),
          isWindows: true,
          installedVersionReader: () async => '1.6.0',
        );
        addTearDown(service.close);

        final first = await service.checkForUpdates();
        expect(first.release!.version.toString(), '1.7.0');
        expect(first.release!.description, 'Notas antiguas: paa comodidad.');

        body = 'Gestor de descarga para más comodidad.';
        final refreshed = await service.checkForUpdates();
        expect(refreshed.release!.version.toString(), '1.7.0');
        expect(refreshed.release!.description, body);
      },
    );

    test('Windows transport uses verified OS roots and manual redirects', () {
      expect(
        windowsUpdateClientSettings.tlsSettings?.rootCertSource,
        RootCertSource.platform,
      );
      expect(
        windowsUpdateClientSettings.tlsSettings?.verifyCertificates,
        isTrue,
      );
      expect(
        windowsUpdateClientSettings.redirectSettings?.runtimeType,
        RedirectSettings.none().runtimeType,
      );
      expect(windowsUpdateClientSettings.proxySettings, isNull);
    });

    test('Inno output name and updater selector share the pubspec version', () async {
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
      expect(setup, contains('AppId={{C7098677-ADDE-4FE4-A0FA-E24AC63B3CD0}'));
      expect(setup, contains('CloseApplications=yes'));
      expect(
        setup,
        contains(
          'Check: not IsUpdaterDrivenInstall and not VCRuntimeRestartRequired;',
        ),
      );
      expect(setup, contains("Pos('/log=', Value) = 1"));
      expect(setup, contains('Flags: nowait postinstall skipifsilent'));
      expect(setup, isNot(contains('RestartApplications=')));
      expect(
        setup,
        contains('#define ProjectDir RemoveBackslashUnlessRoot(SourcePath)'),
      );
      expect(setup, contains('#define BuildDir GetEnv("SUELOSAR_BUILD_DIR")'));
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
      expect(
        setup,
        contains('#define VCRuntimeRequiredVersion "14.51.36231.0"'),
      );
      expect(setup, contains('Source: "{#VCRedistPath}"; Flags: dontcopy'));
      expect(setup, contains('function PrepareToInstall'));
      expect(setup, contains('VCRuntimeRestartRequired'));
      expect(setup, contains('UpdaterRestartMarkerPath'));
      expect(setup, contains('Visual C++ Runtime requires a Windows restart.'));
      expect(setup, contains('Flutter Windows Release directory is missing'));
      expect(setup, contains('Flutter Windows Release executable is missing'));
      expect(
        setup,
        contains('Flutter Windows Release installer helper is missing'),
      );
      expect(setup, contains('Installer icon is missing'));

      final serviceImplementation = await File(
        'lib/services/windows_update_service_io.dart',
      ).readAsString();
      expect(
        serviceImplementation,
        contains('_issuedDownloadChecks.remove(check)'),
      );
      expect(serviceImplementation, contains('bool get canLaunchInstaller'));
      expect(serviceImplementation, contains('helper.existsSync()'));
      expect(serviceImplementation, contains('bytes[0] == 0x4d'));

      final helper = await File(
        'windows/runner/update_helper.cpp',
      ).readAsString();
      expect(helper, contains('Sha256File(installer_path) != expected_hash'));
      expect(helper, contains('WaitForSingleObject(parent, 30000)'));
      expect(helper, isNot(contains('TerminateProcess(')));
      expect(helper, contains('launch.lpVerb = L"runas"'));
      expect(
        helper,
        isNot(contains('VersionMatches(app_path, expected_version)')),
      );
      expect(helper, contains('ResolveInstalledAppPath()'));
      expect(helper, contains('L"InstallLocation"'));
      expect(helper, contains('VersionMatches(installed_app_path'));
      expect(
        helper.replaceAll(RegExp(r'\s+'), ' '),
        contains('version_matches ? installed_app_path : app_path'),
      );
      expect(helper, contains('setup_succeeded && !version_matches'));
      expect(helper, contains('GenerateConfirmationToken()'));
      expect(helper, contains('--suelosar-update-confirmation='));
      expect(helper, contains('WriteSuccessConfirmation(confirmation_token'));
      expect(helper, contains('MoveFileExW(temporary.c_str(), marker.c_str()'));
      expect(
        helper.indexOf('WaitForInputIdle(restarted_process, 15000)'),
        lessThan(helper.indexOf('WriteSuccessConfirmation(confirmation_token')),
      );
      expect(
        helper.indexOf('if (!version_matches) return 1;'),
        lessThan(helper.indexOf('WriteSuccessConfirmation(confirmation_token')),
      );
      expect(helper, contains('vcruntime-restart-required.flag'));
      expect(helper, contains('return 3010;'));
      expect(helper, contains('DeleteUpdateDirectory(update_directory)'));
      expect(helper, contains('GetEnvironmentVariableW(L"LOCALAPPDATA"'));
      expect(helper, contains('path / L"SuelosAR" / L"Updates"'));
      expect(
        helper,
        contains('IsDirectChild(persistent_root, update_directory)'),
      );
      expect(helper, contains('IsAllowedUpdateDirectory(update_directory'));
      expect(helper, contains('IsWithin(temp_path, helper_directory)'));
      expect(helper, contains('ERROR_UPDATE_PATH'));
      final runnerCmake = await File(
        'windows/runner/CMakeLists.txt',
      ).readAsString();
      expect(runnerCmake, contains('add_executable(suelosar_update_helper'));
      final rootCmake = await File('windows/CMakeLists.txt').readAsString();
      expect(rootCmake, contains('install(TARGETS suelosar_update_helper'));

      final buildScript = await File(
        'tool/build_windows_installer.ps1',
      ).readAsString();
      expect(buildScript, contains(r"Join-Path $PSScriptRoot '..'"));
      expect(buildScript, contains(r'[string]$BuildDir'));
      expect(buildScript, contains("'build\\windows\\x64\\runner\\Release'"));
      expect(
        buildScript,
        contains("'windows\\runner\\resources\\app_icon.ico'"),
      );
      expect(buildScript, contains("'artifacts\\windows-installer'"));
      expect(buildScript, contains("'tool\\prerequisites\\vc_redist.x64.exe'"));
      expect(buildScript, contains(r'[string]$OutputDir'));
      expect(buildScript, contains(r'--output-dir=$OutputDir'));
      expect(buildScript, contains('Required installer input is missing'));
      expect(buildScript, contains('suelosar_update_helper.exe'));
      expect(buildScript, contains('0x4D'));
      expect(buildScript, contains('0x5A'));
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
          assets: [_installerAsset(version: version, digest: 'sha256:$digest')],
        ),
      );
      final result = await service.checkForUpdates();

      expect(result.status, WindowsUpdateStatus.updateAvailable);
      expect(result.installer!.name, expectedName);
      service.close();
    });

    test('unsupported platform is reported without an HTTP request', () async {
      final service = WindowsUpdateService(
        client: MockClient((_) async => fail('unexpected request')),
        isWindows: false,
      );
      final result = await service.checkForUpdates();
      expect(result.status, WindowsUpdateStatus.unsupportedPlatform);
      service.close();
    });

    test(
      'uses the Web-SuelosAR release endpoint and accepts its release',
      () async {
        expect(
          WindowsUpdateService.latestReleaseUrl,
          'https://api.github.com/repos/eljerexd/Web-SuelosAR/releases/latest',
        );
        final digest = List.filled(64, 'd').join();
        final service = _service(
          release: _releaseJson(
            tag: 'v1.8.0',
            assets: [_installerAsset(digest: 'sha256:$digest')],
          ),
        );

        final result = await service.checkForUpdates();

        expect(result.status, WindowsUpdateStatus.updateAvailable);
        expect(result.release!.htmlUrl.host, 'github.com');
        expect(
          result.release!.htmlUrl.path,
          '/eljerexd/Web-SuelosAR/releases/tag/v1.8.0',
        );
        expect(
          result.installer!.downloadUrl.path,
          '/eljerexd/Web-SuelosAR/releases/download/v1.8.0/SuelosAR-Setup-1.8.0.exe',
        );
        service.close();
      },
    );

    test(
      'rejects release metadata hosted by the source-code repository',
      () async {
        final service = _service(
          release: _releaseJson(
            tag: 'v1.8.0',
            assets: const [],
            releaseUrl:
                'https://github.com/eljerexd/suelosar/releases/tag/v1.8.0',
          ),
        );

        final result = await service.checkForUpdates();

        expect(result.status, WindowsUpdateStatus.invalidRelease);
        expect(result.error!.code, WindowsUpdateErrorCode.invalidRelease);
        service.close();
      },
    );

    test(
      'rejects installer assets hosted by the source-code repository',
      () async {
        final digest = List.filled(64, 'e').join();
        final service = _service(
          release: _releaseJson(
            tag: 'v1.8.0',
            assets: [
              _installerAsset(
                digest: 'sha256:$digest',
                url:
                    'https://github.com/eljerexd/suelosar/releases/download/v1.8.0/SuelosAR-Setup-1.8.0.exe',
              ),
            ],
          ),
        );

        final result = await service.checkForUpdates();

        expect(result.status, WindowsUpdateStatus.failed);
        expect(result.error!.code, WindowsUpdateErrorCode.invalidRelease);
        service.close();
      },
    );

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
              'https://github.com/eljerexd/Web-SuelosAR/releases/download/v1.8.0/SuelosAR-Setup-1.8.0.exe.sha256',
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
              'https://github.com/eljerexd/Web-SuelosAR/releases/download/v1.8.0/SuelosAR-Setup-1.8.0.exe',
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
              'https://github.com/eljerexd/Web-SuelosAR/releases/download/v1.7.9/SuelosAR-Setup.exe',
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
              'https://github.com/eljerexd/Web-SuelosAR/releases/download/v1.8.0/SuelosAR-Setup-1.7.9.exe';
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

    test('restores only an intact installer from its update storage', () async {
      final root = await Directory.systemTemp.createTemp('update-restore-');
      final nested = Directory('${root.path}${Platform.pathSeparator}pending');
      await nested.create();
      final bytes = <int>[0x4d, 0x5a, 1, 2, 3, 4];
      final installer = File(
        '${nested.path}${Platform.pathSeparator}SuelosAR-Setup-1.8.0.exe',
      );
      await installer.writeAsBytes(bytes);
      final digest = sha256.convert(bytes).toString();
      final service = WindowsUpdateService(
        client: MockClient((_) async => http.Response('', 200)),
        isWindows: true,
        temporaryDirectory: root,
      );

      expect(
        await service.restoreDownloadedInstaller(
          path: installer.path,
          expectedSha256: digest,
          version: '1.8.0',
        ),
        isTrue,
      );
      expect(
        (await service.verifyDownloadedInstaller(
          installer.path,
          digest,
        )).succeeded,
        isTrue,
      );
      expect(
        await service.restoreDownloadedInstaller(
          path: installer.path,
          expectedSha256: '0' * 64,
          version: '1.8.0',
        ),
        isFalse,
      );
      expect(
        await service.restoreDownloadedInstaller(
          path: installer.path,
          expectedSha256: digest,
          version: '1.8.1',
        ),
        isFalse,
      );

      service.close();
      await root.delete(recursive: true);
    });

    test('blocks launch when the bundled helper is unavailable', () async {
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
          if (request.url.toString() == WindowsUpdateService.latestReleaseUrl) {
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
      expect(result.status, WindowsUpdateOperationStatus.lifecycleUnavailable);
      expect(
        result.error!.code,
        WindowsUpdateErrorCode.installerLifecycleUnavailable,
      );
      expect(startedPath, isNull);
      await root.delete(recursive: true);
      service.close();
    });

    test(
      'launches only this service verified installer through lifecycle',
      () async {
        final bytes = utf8.encode('MZ verified placeholder');
        final digest = sha256.convert(bytes).toString();
        final root = await Directory.systemTemp.createTemp('update-lifecycle-');
        final helper = File('${root.path}${Platform.pathSeparator}helper.exe');
        final app = File('${root.path}${Platform.pathSeparator}suelosar.exe');
        await helper.writeAsBytes([0x4d, 0x5a, 0, 0]);
        await app.writeAsBytes([0x4d, 0x5a, 0, 0]);
        final asset = Map<String, Object?>.from(
          _installerAsset(digest: 'sha256:$digest'),
        )..['size'] = bytes.length;
        final release = _releaseJson(tag: 'v1.8.0', assets: [asset]);
        var calls = 0;
        String? receivedPath;
        String? receivedHash;
        String? receivedVersion;
        String? receivedDirectory;
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
          installerHelperResolver: () => helper,
          applicationExecutableResolver: () => app,
          installerLifecycleStarter: (path, hash, version, directory) async {
            calls++;
            receivedPath = path;
            receivedHash = hash;
            receivedVersion = version;
            receivedDirectory = directory;
          },
        );

        expect(service.canLaunchInstaller, isTrue);
        final check = await service.checkForUpdates();
        final downloaded = await service.downloadUpdate(check);
        expect(downloaded.succeeded, isTrue);
        final result = await service.launchInstaller(downloaded.installerPath!);

        expect(result.succeeded, isTrue);
        expect(calls, 1);
        expect(receivedPath, downloaded.installerPath);
        expect(receivedHash, digest);
        expect(receivedVersion, '1.8.0');
        expect(
          receivedDirectory,
          startsWith('${root.path}${Platform.pathSeparator}suelosar-update-'),
        );

        final otherService = WindowsUpdateService(
          isWindows: true,
          installerHelperResolver: () => helper,
          applicationExecutableResolver: () => app,
          installerLifecycleStarter: (_, _, _, _) async => fail('must not run'),
        );
        expect(
          (await otherService.launchInstaller(
            downloaded.installerPath!,
          )).error?.code,
          WindowsUpdateErrorCode.installerNotVerified,
        );

        service.close();
        otherService.close();
        await root.delete(recursive: true);
      },
    );

    test(
      'modified downloaded installer is rejected before helper launch',
      () async {
        final bytes = utf8.encode('MZ original installer');
        final digest = sha256.convert(bytes).toString();
        final root = await Directory.systemTemp.createTemp('update-tamper-');
        final helper = File('${root.path}${Platform.pathSeparator}helper.exe')
          ..writeAsBytesSync([0x4d, 0x5a]);
        final app = File('${root.path}${Platform.pathSeparator}suelosar.exe')
          ..writeAsBytesSync([0x4d, 0x5a]);
        final asset = Map<String, Object?>.from(
          _installerAsset(digest: 'sha256:$digest'),
        )..['size'] = bytes.length;
        final service = WindowsUpdateService(
          client: MockClient((request) async {
            if (request.url.toString() ==
                WindowsUpdateService.latestReleaseUrl) {
              return http.Response(
                jsonEncode(_releaseJson(tag: 'v1.8.0', assets: [asset])),
                200,
              );
            }
            return http.Response.bytes(bytes, 200);
          }),
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          temporaryDirectory: root,
          installerHelperResolver: () => helper,
          applicationExecutableResolver: () => app,
          installerLifecycleStarter: (_, _, _, _) async => fail('must not run'),
        );
        final downloaded = await service.downloadUpdate(
          await service.checkForUpdates(),
        );
        final installer = File(downloaded.installerPath!);
        await installer.writeAsString('tampered');

        final result = await service.launchInstaller(installer.path);

        expect(result.error?.code, WindowsUpdateErrorCode.checksumMismatch);
        expect(await installer.exists(), isFalse);
        service.close();
        await root.delete(recursive: true);
      },
    );

    test(
      'helper startup failure is reported without claiming success',
      () async {
        final bytes = utf8.encode('MZ verified placeholder');
        final digest = sha256.convert(bytes).toString();
        final root = await Directory.systemTemp.createTemp(
          'update-helper-fail-',
        );
        final helper = File('${root.path}${Platform.pathSeparator}helper.exe')
          ..writeAsBytesSync([0x4d, 0x5a]);
        final app = File('${root.path}${Platform.pathSeparator}suelosar.exe')
          ..writeAsBytesSync([0x4d, 0x5a]);
        final asset = Map<String, Object?>.from(
          _installerAsset(digest: 'sha256:$digest'),
        )..['size'] = bytes.length;
        final service = WindowsUpdateService(
          client: MockClient((request) async {
            if (request.url.toString() ==
                WindowsUpdateService.latestReleaseUrl) {
              return http.Response(
                jsonEncode(_releaseJson(tag: 'v1.8.0', assets: [asset])),
                200,
              );
            }
            return http.Response.bytes(bytes, 200);
          }),
          isWindows: true,
          installedVersionReader: () async => '1.7.0',
          temporaryDirectory: root,
          installerHelperResolver: () => helper,
          applicationExecutableResolver: () => app,
          installerLifecycleStarter: (_, _, _, _) =>
              Future<void>.error(ProcessException('helper', [], 'failed')),
        );
        final downloaded = await service.downloadUpdate(
          await service.checkForUpdates(),
        );

        final result = await service.launchInstaller(downloaded.installerPath!);

        expect(result.error?.code, WindowsUpdateErrorCode.launchFailed);
        service.close();
        await root.delete(recursive: true);
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
  String? releaseUrl,
  String body = 'Release notes',
}) => {
  'tag_name': tag,
  'name': tag,
  'body': body,
  'draft': false,
  'prerelease': false,
  'published_at': '2026-11-01T12:00:00Z',
  'html_url':
      releaseUrl ??
      'https://github.com/eljerexd/Web-SuelosAR/releases/tag/$tag',
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
      'https://github.com/eljerexd/Web-SuelosAR/releases/download/v$version/SuelosAR-Setup-$version.exe',
};

WindowsReleaseInfo _releaseInfo() => WindowsReleaseInfo(
  tag: 'v1.8.0',
  version: SemanticVersion.tryParse('1.8.0')!,
  name: 'v1.8.0',
  description: '',
  publishedAt: DateTime.utc(2026),
  assets: const [],
  htmlUrl: Uri.parse(
    'https://github.com/eljerexd/Web-SuelosAR/releases/tag/v1.8.0',
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
