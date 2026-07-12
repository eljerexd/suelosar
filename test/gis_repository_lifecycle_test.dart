import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repository close waits for initialization already in progress', () async {
    final directory = await Directory.systemTemp.createTemp(
      'suelosar-repository-close-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bundle = _DelayedAssetBundle();
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: 'maps/test.pmtiles',
      versionAssetPath: 'maps/test.sha256',
      layerName: 'test',
      assetBundle: bundle,
      supportDirectoryProvider: () async => directory,
    );

    final initialization = repository.initialize();
    final initializationResult = expectLater(initialization, throwsA(anything));
    var closeCompleted = false;
    final closing = repository.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    final closedBeforeInitializationFinished = closeCompleted;
    bundle.releaseVersion();
    await initializationResult;
    await closing;

    expect(closedBeforeInitializationFinished, isFalse);
  });
}

class _DelayedAssetBundle extends CachingAssetBundle {
  final Completer<ByteData> _version = Completer<ByteData>();

  void releaseVersion() {
    _version.complete(
      ByteData.sublistView(
        Uint8List.fromList(List<int>.filled(64, 'a'.codeUnitAt(0))),
      ),
    );
  }

  @override
  Future<ByteData> load(String key) {
    if (key == 'maps/test.sha256') return _version.future;
    if (key == 'maps/test.pmtiles') {
      return Future<ByteData>.value(
        ByteData.sublistView(Uint8List.fromList(const <int>[0, 1, 2, 3])),
      );
    }
    throw StateError('Unexpected asset: $key');
  }
}
