import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:suelosar/services/windows_update_service.dart';
import 'package:suelosar/services/windows_differential_update.dart';

const _stagingBase = String.fromEnvironment(
  'SUelosAR_UPDATE_STAGING_BASE',
  defaultValue: '',
);
const _requireDifferentialStaging = bool.fromEnvironment(
  'SUelosAR_UPDATE_REQUIRE_DIFFERENTIAL',
  defaultValue: false,
);
const _renderer =
    bool.fromEnvironment('SUelosAR_MAPLIBRE_NATIVE', defaultValue: false)
    ? 'maplibre-native'
    : 'flutter-map-fallback';

void main() {
  test('normal update client accepts configured staging asset origin', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'suelosar-update-client-routing-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final localExecutable = utf8.encode('installed 1.8.1 app');
    final helper = utf8.encode('installed differential helper');
    final localManifest = File(
      '${temporary.path}${Platform.pathSeparator}installation-manifest.json',
    );
    await localManifest.writeAsString(
      jsonEncode({
        'schema_version': 1,
        'app_version': '1.8.1',
        'build_number': 26,
        'platform': 'windows-x64',
        'renderer': _renderer,
        'compatibility_id': 'suelosar-windows-x64-v1',
        'installation_id': '00000000-0000-4000-8000-000000000001',
        'generated_at_utc': '2026-11-16T00:00:00.000Z',
        'files': [
          _entry('suelosar.exe', localExecutable),
          _entry('suelosar_update_helper.exe', helper),
        ],
      }),
    );

    final targetExecutable = utf8.encode('updated 1.8.2 app');
    final deltaBytes = utf8.encode('verified ZIP payload');
    final deltaSha = sha256.convert(deltaBytes).toString();
    final manifest = <String, Object?>{
      'schema_version': 1,
      'version': '1.8.2+27',
      'app_version': '1.8.2',
      'build_number': 27,
      'required_installation_schema': 1,
      'minimum_supported_baseline': '1.8.1+26',
      'platform': 'windows-x64',
      'architecture': 'x64',
      'renderer': _renderer,
      'compatibility_id': 'suelosar-windows-x64-v1',
      'package': {
        'name': WindowsDifferentialManifest.packageAssetName(
          UpdateVersion.tryParse('1.8.2+27')!,
          _renderer,
        ),
        'size': deltaBytes.length,
        'sha256': deltaSha,
        'files': [
          {
            ..._entry('suelosar.exe', targetExecutable),
            'change_type': 'modified',
          },
        ],
      },
      'files': [
        _entry('suelosar.exe', targetExecutable),
        _entry('suelosar_update_helper.exe', helper),
      ],
      'added_files': <String>[],
      'modified_files': ['suelosar.exe'],
      'removed_files': <String>[],
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    final manifestName = WindowsDifferentialManifest.manifestAssetName(
      UpdateVersion.tryParse('1.8.2+27')!,
      _renderer,
    );
    final packageName = manifest['package']! as Map<String, Object?>;
    final deltaName = packageName['name']! as String;
    final tag = 'v1.8.2+27';
    final assetOrigin = _stagingBase.isEmpty
        ? 'https://github.com'
        : _stagingBase;
    final releasePage = _stagingBase.isEmpty
        ? 'https://github.com/eljerexd/Web-SuelosAR/releases/tag/$tag'
        : '$_stagingBase/eljerexd/Web-SuelosAR/releases/tag/$tag';
    final manifestUrl =
        '$assetOrigin/eljerexd/Web-SuelosAR/releases/download/'
        '$tag/$manifestName';
    final deltaUrl =
        '$assetOrigin/eljerexd/Web-SuelosAR/releases/download/'
        '$tag/$deltaName';
    final setupUrl =
        '$assetOrigin/eljerexd/Web-SuelosAR/releases/download/'
        '$tag/SuelosAR-Setup-1.8.2+27.exe';
    final expectedManifestRequest = _stagingBase.isEmpty
        ? manifestUrl
        : '$_stagingBase/eljerexd/Web-SuelosAR/releases/download/$tag/$manifestName';
    final expectedLatestRequest = _stagingBase.isEmpty
        ? WindowsUpdateService.latestReleaseUrl
        : '$_stagingBase/repos/eljerexd/Web-SuelosAR/releases/latest';
    final releaseBody = jsonEncode({
      'tag_name': tag,
      'name': 'SuelosAR 1.8.2',
      'draft': false,
      'prerelease': false,
      'published_at': '2026-11-16T12:00:00Z',
      'html_url': releasePage,
      'assets': [
        _asset(
          'SuelosAR-Setup-1.8.2+27.exe',
          setupUrl,
          utf8.encode('full setup'),
        ),
        _asset(manifestName, manifestUrl, manifestBytes),
        _asset(deltaName, deltaUrl, deltaBytes),
      ],
    });
    final seenRequests = <String>[];
    final service = WindowsUpdateService(
      isWindows: true,
      installedVersionReader: () async => '1.8.1+26',
      installationManifestResolver: () => localManifest,
      client: MockClient((request) async {
        seenRequests.add(request.url.toString());
        if (request.url.toString() == expectedLatestRequest) {
          return http.Response(releaseBody, 200);
        }
        if (request.url.toString() == expectedManifestRequest) {
          return http.Response.bytes(manifestBytes, 200);
        }
        return http.Response('unexpected request', 404);
      }),
    );
    addTearDown(service.close);

    final result = await service.checkForUpdates();

    expect(result.updateAvailable, isTrue);
    expect(result.usesDifferentialPackage, isTrue);
    expect(result.downloadAsset?.name, deltaName);
    expect(result.downloadSha256, deltaSha);
    expect(seenRequests, contains(expectedLatestRequest));
    expect(seenRequests, contains(expectedManifestRequest));
    expect(seenRequests, isNot(contains(deltaUrl)));

    if (_stagingBase.isNotEmpty && _requireDifferentialStaging) {
      for (final redirectTarget in [
        'http://127.0.0.1:38443/not-https',
        'https://127.0.0.1:38444/wrong-port',
        'https://downloads.example.test/external',
      ]) {
        final redirectRequests = <Uri>[];
        final redirectService = WindowsUpdateService(
          isWindows: true,
          installedVersionReader: () async => '1.8.1+26',
          installationManifestResolver: () => localManifest,
          client: MockClient((request) async {
            redirectRequests.add(request.url);
            if (request.url.toString() == expectedLatestRequest) {
              return http.Response(releaseBody, 200);
            }
            if (request.url.toString() == expectedManifestRequest) {
              return http.Response(
                '',
                302,
                headers: {'location': redirectTarget},
              );
            }
            return http.Response('unexpected request', 404);
          }),
        );

        final blocked = await redirectService.checkForUpdates();

        expect(blocked.status, WindowsUpdateStatus.invalidRelease);
        expect(blocked.canDownload, isFalse);
        expect(redirectRequests, isNot(contains(Uri.parse(redirectTarget))));
        redirectService.close();
      }
    }
  });
}

Map<String, Object?> _entry(String path, List<int> bytes) => {
  'path': path,
  'size': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'classification': 'executable',
  'managed_by_updater': true,
};

Map<String, Object?> _asset(String name, String url, List<int> bytes) => {
  'id': name.hashCode & 0x7fffffff,
  'name': name,
  'size': bytes.length,
  'digest': 'sha256:${sha256.convert(bytes)}',
  'browser_download_url': url,
};
