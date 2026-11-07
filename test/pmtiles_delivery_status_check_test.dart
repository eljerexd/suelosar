import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';

void main() {
  test('a cold probe resolves to the current installed state', () async {
    final delivery = _ProbeableDelivery();
    await delivery.check(
      installed: Future<bool>.value(true),
      uninstallPending: Future<bool>.value(false),
    );
    expect(delivery.status, PmtilesDeliveryStatus.available);

    await delivery.check(
      installed: Future<bool>.value(false),
      uninstallPending: Future<bool>.value(false),
    );
    expect(delivery.status, PmtilesDeliveryStatus.notInstalled);
    expect(delivery.clearCount, 1);
  });

  test('an older asynchronous probe cannot overwrite a newer result', () async {
    final delivery = _ProbeableDelivery();
    final staleResult = Completer<bool>();
    final newestResult = Completer<bool>();

    final stale = delivery.check(
      installed: staleResult.future,
      uninstallPending: Future<bool>.value(false),
    );
    final newest = delivery.check(
      installed: newestResult.future,
      uninstallPending: Future<bool>.value(false),
    );
    newestResult.complete(false);
    await newest;
    staleResult.complete(true);
    await stale;

    expect(delivery.status, PmtilesDeliveryStatus.notInstalled);
  });

  test('a status probe cannot replace an active download state', () async {
    final delivery = _ProbeableDelivery();
    final installedResult = Completer<bool>();
    final pendingCheck = delivery.check(
      installed: installedResult.future,
      uninstallPending: Future<bool>.value(false),
    );

    delivery.startDownload();
    installedResult.complete(true);
    await pendingCheck;

    expect(delivery.status, PmtilesDeliveryStatus.downloading);
  });
}

class _ProbeableDelivery extends PmtilesDelivery {
  PmtilesDeliveryStatus _status = PmtilesDeliveryStatus.notInstalled;
  int clearCount = 0;

  @override
  PmtilesDeliveryStatus get status => _status;

  Future<void> check({
    required Future<bool> installed,
    required Future<bool> uninstallPending,
  }) => reconcileInstalledModule(
    isComponentInstalled: () => installed,
    isUninstallPending: () => uninstallPending,
    clearUninstallPending: () async {
      clearCount++;
    },
    setStatus: (status) {
      _status = status;
      notifyListeners();
    },
  );

  void startDownload() {
    invalidateStatusChecks();
    _status = PmtilesDeliveryStatus.downloading;
    notifyListeners();
  }

  @override
  Future<void> checkStatus() async {}

  @override
  Future<void> download() async {}

  @override
  Future<void> uninstall() async {}

  @override
  File resolveWindowsArchiveFile() => File('unused');
}
