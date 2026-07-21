import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/pairing/device_pairing_backend.dart';
import 'package:suelosar/pairing/device_pairing_models.dart';
import 'package:suelosar/services/device_pairing_service.dart';

void main() {
  test('stored Sync Group determines whether the device is linked', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await DevicePairingService.hasStoredSyncGroup(), isFalse);

    SharedPreferences.setMockInitialValues(<String, Object>{
      DevicePairingService.groupStorageKey:
          '99999999-9999-4999-8999-999999999999',
    });
    expect(await DevicePairingService.hasStoredSyncGroup(), isTrue);
  });

  test('pairing sessions expose only an opaque one-use token', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final backend = _PairingBackendFake();
    final service = DevicePairingService(
      backend: backend,
      registrationLoader: () async => _registration,
    );

    await service.start();
    expect(service.hasPeers, isFalse);
    final session = await service.createPairingSession();

    expect(session.pairingCode, '482913');
    expect(session.qrPayload, 'suelosar://pair?token=opaque-secret');
    expect(session.qrPayload, isNot(contains(_registration.deviceUuid)));
    expect(session.qrPayload, isNot(contains(backend.group.groupUuid)));
    expect(
      (await SharedPreferences.getInstance()).getString(
        DevicePairingService.groupStorageKey,
      ),
      isNull,
    );

    service.dispose();
  });

  test('pairing session retries a failed device registration', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final backend = _PairingBackendFake()..registrationFailuresRemaining = 1;
    final service = DevicePairingService(
      backend: backend,
      registrationLoader: () async => _registration,
    );

    await expectLater(service.start(), throwsA(isA<DevicePairingException>()));
    final session = await service.createPairingSession();

    expect(backend.registrationCalls, 2);
    expect(session.pairingCode, '482913');
    expect(session.qrPayload, 'suelosar://pair?token=opaque-secret');

    service.dispose();
  });

  test('manual and QR pairing share the same service workflow', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final backend = _PairingBackendFake();
    final service = DevicePairingService(
      backend: backend,
      registrationLoader: () async => _registration,
    );
    await service.start();

    await service.pairWithCode('482 913');
    expect(backend.claimedCode, '482913');
    expect(service.devices, hasLength(2));
    expect(service.hasPeers, isTrue);
    expect(service.peerCount, 1);
    expect(
      (await SharedPreferences.getInstance()).getString(
        DevicePairingService.groupStorageKey,
      ),
      backend.group.groupUuid,
    );

    await service.pairWithToken('suelosar://pair?token=another-opaque-secret');
    expect(backend.claimedToken, 'another-opaque-secret');

    final other = service.devices.last;
    await service.renameDevice(other, 'Notebook de campo');
    expect(service.devices.last.deviceName, 'Notebook de campo');
    await service.removeDevice(service.devices.last);
    expect(service.devices, hasLength(1));
    expect(service.hasPeers, isFalse);
    expect(service.peerCount, 0);
    expect(service.group, isNull);
    expect(
      (await SharedPreferences.getInstance()).getString(
        DevicePairingService.groupStorageKey,
      ),
      isNull,
    );

    service.dispose();
  });

  test('refresh reactivates the group when a new peer appears', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final backend = _PairingBackendFake();
    final service = DevicePairingService(
      backend: backend,
      registrationLoader: () async => _registration,
    );
    await service.start();
    expect(service.hasPeers, isFalse);

    backend.storedDevices = [
      ...backend.storedDevices,
      PairedDevice(
        deviceUuid: '22222222-2222-4222-8222-222222222222',
        deviceName: 'Escritorio',
        platform: 'Windows',
        pairedAt: DateTime.utc(2026, 7, 16),
      ),
    ];
    await service.refreshDevices();

    expect(service.hasPeers, isTrue);
    expect(service.group?.groupUuid, backend.group.groupUuid);
    expect(
      (await SharedPreferences.getInstance()).getString(
        DevicePairingService.groupStorageKey,
      ),
      backend.group.groupUuid,
    );

    service.dispose();
  });

  test(
    'invalid manual codes are rejected before reaching the backend',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final backend = _PairingBackendFake();
      final service = DevicePairingService(
        backend: backend,
        registrationLoader: () async => _registration,
      );
      await service.start();

      expect(
        () => service.pairWithCode('123'),
        throwsA(isA<DevicePairingException>()),
      );
      expect(backend.claimCount, 0);

      service.dispose();
    },
  );
}

const _registration = PairingDeviceRegistration(
  deviceUuid: '11111111-1111-4111-8111-111111111111',
  deviceName: 'Teléfono de campo',
  platform: 'Android',
);

class _PairingBackendFake implements DevicePairingBackend {
  final group = SyncGroup(
    groupUuid: '99999999-9999-4999-8999-999999999999',
    ownerDeviceUuid: _registration.deviceUuid,
    createdAt: DateTime.utc(2026, 7, 15),
  );
  String? claimedCode;
  String? claimedToken;
  int claimCount = 0;
  int registrationCalls = 0;
  int registrationFailuresRemaining = 0;

  late List<PairedDevice> storedDevices = [_currentDevice];

  PairedDevice get _currentDevice => PairedDevice(
    deviceUuid: _registration.deviceUuid,
    deviceName: _registration.deviceName,
    platform: _registration.platform,
    pairedAt: DateTime.utc(2026, 7, 15),
    isCurrentDevice: true,
  );

  @override
  bool get isConfigured => true;

  @override
  Future<PairingClaimResult> claimPairingToken({
    required PairingDeviceRegistration registration,
    String? token,
    String? pairingCode,
  }) async {
    claimCount++;
    claimedCode = pairingCode;
    claimedToken = token;
    storedDevices = [
      _currentDevice,
      PairedDevice(
        deviceUuid: '22222222-2222-4222-8222-222222222222',
        deviceName: 'Escritorio',
        platform: 'Windows',
        pairedAt: DateTime.utc(2026, 7, 15, 1),
      ),
    ];
    return PairingClaimResult(group: group, devices: storedDevices);
  }

  @override
  Future<PairingSession> createPairingSession(
    PairingDeviceRegistration registration,
  ) async => PairingSession(
    token: 'opaque-secret',
    pairingCode: '482913',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  );

  @override
  Future<List<PairedDevice>> listDevices(String currentDeviceUuid) async =>
      storedDevices;

  @override
  Future<PairingBootstrapResult> registerCurrentDevice(
    PairingDeviceRegistration registration,
  ) async {
    registrationCalls++;
    if (registrationFailuresRemaining > 0) {
      registrationFailuresRemaining--;
      throw const DevicePairingException('Registro temporalmente fallido.');
    }
    return PairingBootstrapResult(group: group, devices: storedDevices);
  }

  @override
  Future<void> removeDevice({
    required String deviceUuid,
    required String currentDeviceUuid,
  }) async {
    storedDevices = storedDevices
        .where((device) => device.deviceUuid != deviceUuid)
        .toList();
  }

  @override
  Future<PairedDevice> renameDevice({
    required String deviceUuid,
    required String deviceName,
    required String currentDeviceUuid,
  }) async {
    final existing = storedDevices.firstWhere(
      (device) => device.deviceUuid == deviceUuid,
    );
    final updated = existing.copyWith(deviceName: deviceName);
    storedDevices = [
      for (final device in storedDevices)
        if (device.deviceUuid == deviceUuid) updated else device,
    ];
    return updated;
  }
}
