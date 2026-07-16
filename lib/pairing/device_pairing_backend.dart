import 'device_pairing_models.dart';

abstract interface class DevicePairingBackend {
  bool get isConfigured;

  Future<PairingBootstrapResult> registerCurrentDevice(
    PairingDeviceRegistration registration,
  );

  Future<PairingSession> createPairingSession(
    PairingDeviceRegistration registration,
  );

  Future<PairingClaimResult> claimPairingToken({
    required PairingDeviceRegistration registration,
    String? token,
    String? pairingCode,
  });

  Future<List<PairedDevice>> listDevices(String currentDeviceUuid);

  Future<PairedDevice> renameDevice({
    required String deviceUuid,
    required String deviceName,
    required String currentDeviceUuid,
  });

  Future<void> removeDevice({
    required String deviceUuid,
    required String currentDeviceUuid,
  });
}

class UnavailableDevicePairingBackend implements DevicePairingBackend {
  const UnavailableDevicePairingBackend();

  @override
  bool get isConfigured => false;

  Never _unavailable() {
    throw const DevicePairingException(
      'El servicio de sincronización no está configurado.',
    );
  }

  @override
  Future<PairingClaimResult> claimPairingToken({
    required PairingDeviceRegistration registration,
    String? token,
    String? pairingCode,
  }) async => _unavailable();

  @override
  Future<PairingSession> createPairingSession(
    PairingDeviceRegistration registration,
  ) async => _unavailable();

  @override
  Future<List<PairedDevice>> listDevices(String currentDeviceUuid) async =>
      _unavailable();

  @override
  Future<PairingBootstrapResult> registerCurrentDevice(
    PairingDeviceRegistration registration,
  ) async => _unavailable();

  @override
  Future<void> removeDevice({
    required String deviceUuid,
    required String currentDeviceUuid,
  }) async => _unavailable();

  @override
  Future<PairedDevice> renameDevice({
    required String deviceUuid,
    required String deviceName,
    required String currentDeviceUuid,
  }) async => _unavailable();
}
