enum DevicePairingStatus { idle, loading, creating, joining, updating, error }

class SyncGroup {
  const SyncGroup({
    required this.groupUuid,
    required this.ownerDeviceUuid,
    required this.createdAt,
  });

  final String groupUuid;
  final String ownerDeviceUuid;
  final DateTime createdAt;
}

class PairedDevice {
  const PairedDevice({
    required this.deviceUuid,
    required this.deviceName,
    required this.platform,
    required this.pairedAt,
    this.lastSynchronizationAt,
    this.isCurrentDevice = false,
  });

  final String deviceUuid;
  final String deviceName;
  final String platform;
  final DateTime pairedAt;
  final DateTime? lastSynchronizationAt;
  final bool isCurrentDevice;

  PairedDevice copyWith({
    String? deviceName,
    DateTime? lastSynchronizationAt,
    bool? isCurrentDevice,
  }) {
    return PairedDevice(
      deviceUuid: deviceUuid,
      deviceName: deviceName ?? this.deviceName,
      platform: platform,
      pairedAt: pairedAt,
      lastSynchronizationAt:
          lastSynchronizationAt ?? this.lastSynchronizationAt,
      isCurrentDevice: isCurrentDevice ?? this.isCurrentDevice,
    );
  }
}

class PairingSession {
  const PairingSession({
    required this.token,
    required this.pairingCode,
    required this.expiresAt,
  });

  final String token;
  final String pairingCode;
  final DateTime expiresAt;

  String get qrPayload => 'suelosar://pair?token=$token';

  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}

class PairingDeviceRegistration {
  const PairingDeviceRegistration({
    required this.deviceUuid,
    required this.deviceName,
    required this.platform,
  });

  final String deviceUuid;
  final String deviceName;
  final String platform;
}

class PairingBootstrapResult {
  const PairingBootstrapResult({required this.group, required this.devices});

  final SyncGroup group;
  final List<PairedDevice> devices;
}

class PairingClaimResult {
  const PairingClaimResult({required this.group, required this.devices});

  final SyncGroup group;
  final List<PairedDevice> devices;
}

class DevicePairingException implements Exception {
  const DevicePairingException(this.message);

  final String message;

  @override
  String toString() => message;
}
