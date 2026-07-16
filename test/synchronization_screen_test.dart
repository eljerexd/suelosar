import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/app/app_theme.dart';
import 'package:suelosar/pairing/device_pairing_backend.dart';
import 'package:suelosar/pairing/device_pairing_models.dart';
import 'package:suelosar/screens/synchronization_screen.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/device_pairing_service.dart';
import 'package:suelosar/services/synchronization_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';
import 'package:suelosar/sync/sync_coordinator.dart';

void main() {
  testWidgets('bootstrap failures are exposed in synchronization diagnostics', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.sync.error.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      backendConfigured: () => true,
      backendConnected: () => false,
      backendAdapterName: () => 'SupabaseSyncBackendAdapter',
      backendStartupError: () => 'AuthException: anonymous sign-in failed',
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Windows',
        uuid: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        appVersion: '1.0.1',
        platform: 'Windows',
      ),
    );
    final pairingService = _pairingService();

    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Error de inicializaci\u00f3n'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Avanzado'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Avanzado'));
    await tester.pumpAndSettle();
    expect(
      find.text('AuthException: anonymous sign-in failed'),
      findsOneWidget,
    );

    service.dispose();
    pairingService.dispose();
    await engine.dispose();
  });

  testWidgets('manual synchronization shows progress and temporary success', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.sync.button.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final completion = Completer<bool>();
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () => completion.future,
      backendConfigured: () => true,
      backendConnected: () => true,
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Android',
        uuid: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    final pairingService = _pairingService(withPeer: true);
    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.scrollUntilVisible(
      find.text('Sincronizar ahora'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.tap(find.text('Sincronizar ahora'));
    await tester.pump();
    expect(find.text('Sincronizando...'), findsOneWidget);

    completion.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Sincronizado'), findsWidgets);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sincronizar ahora'), findsOneWidget);

    service.dispose();
    pairingService.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  testWidgets('add device opens the Android pairing bottom sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.pairing.sheet.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () async => true,
      backendConfigured: () => true,
      backendConnected: () => true,
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Dispositivo de prueba',
        uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    final pairingService = _pairingService();
    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Agregar dispositivo'),
      250,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.tap(find.text('Agregar dispositivo'));
    await tester.pumpAndSettle();

    expect(find.text('Mostrar código'), findsOneWidget);
    expect(find.text('482913'), findsOneWidget);
    expect(find.text('Vincular este equipo'), findsOneWidget);
    expect(find.textContaining('Vence en'), findsOneWidget);

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    service.dispose();
    pairingService.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  testWidgets('expired pairing code is replaced without a generic error', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.pairing.expiry.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () async => true,
      backendConfigured: () => true,
      backendConnected: () => true,
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Dispositivo de prueba',
        uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    final backend = _ExpiringPairingBackend();
    final pairingService = _pairingService(backend: backend);

    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Agregar dispositivo'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Agregar dispositivo'));
    await tester.pumpAndSettle();
    expect(find.text('111111'), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('El código venció.'), findsOneWidget);
    expect(find.text('Generar otro código'), findsOneWidget);
    expect(find.text('No se pudo completar la vinculación.'), findsNothing);

    await tester.tap(find.text('Generar otro código'));
    await tester.pumpAndSettle();
    expect(backend.createSessionCalls, 2);
    expect(find.text('111111'), findsNothing);
    expect(find.text('222222'), findsOneWidget);
    expect(find.text('El código venció.'), findsNothing);
    expect(find.text('No se pudo completar la vinculación.'), findsNothing);

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    service.dispose();
    pairingService.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  testWidgets('renaming a paired device has a safe dialog lifecycle', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.pairing.rename.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () async => false,
      backendConfigured: () => true,
      backendConnected: () => true,
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Android',
        uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    final pairingService = _pairingService(withPeer: true);

    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Acciones del dispositivo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Renombrar'));
    await tester.pumpAndSettle();
    expect(find.text('Renombrar dispositivo'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Tablet de campo');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(find.text('Tablet de campo'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Acciones del dispositivo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quitar dispositivo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quitar'));
    await tester.pumpAndSettle();

    expect(pairingService.peerCount, 0);
    expect(find.text('Sin vincular'), findsOneWidget);
    expect(find.text('No hay dispositivos vinculados.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sincronizar ahora'),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    pairingService.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  testWidgets('unlinked entry opens pairing without starting synchronization', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.pairing.entry.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    var synchronizationCalls = 0;
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () async {
        synchronizationCalls++;
        return true;
      },
      backendConfigured: () => true,
      backendConnected: () => true,
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Dispositivo de prueba',
        uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    final pairingService = _pairingService();

    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(
        service: service,
        pairingService: pairingService,
        openPairingOnStart: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Vincular este equipo'), findsOneWidget);
    expect(synchronizationCalls, 0);

    service.dispose();
    pairingService.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  testWidgets('synchronization page is responsive on Android and desktop', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SyncCoordinator.lastSuccessfulSyncStorageKey: '2026-07-15T15:52:00.000Z',
      SyncCoordinator.cursorStorageKey: '{"markers":{"uuid":"cursor"}}',
    });
    final connectivity = ConnectivityService();
    final queue = PersistentSyncQueue(storageKey: 'test.sync.ui.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    await queue.enqueue(
      SyncOperation(
        uuid: '11111111-1111-4111-8111-111111111111',
        entityType: SyncEntityType.marker,
        operationType: SyncOperationType.update,
        createdAt: DateTime.utc(2026, 7, 15),
        retryCount: 2,
        payloadReference: 'marker:test',
      ),
    );
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () async => true,
      backendConfigured: () => true,
      backendConnected: () => true,
      backendAdapterName: () => 'FakeSyncBackendAdapter',
      pollingInterval: () => const Duration(seconds: 30),
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Dispositivo de prueba',
        uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    final pairingService = _pairingService();

    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Sincronización'), findsOneWidget);
    expect(find.text('Cambios pendientes'), findsWidgets);
    expect(find.text('Dispositivo de prueba'), findsWidgets);
    expect(find.textContaining('15 jul 2026'), findsOneWidget);
    expect(find.text('Actual'), findsNothing);
    expect(find.text('No hay dispositivos vinculados.'), findsOneWidget);
    expect(find.text('Agregar dispositivo'), findsOneWidget);
    expect(find.text('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), findsNothing);
    expect(tester.takeException(), isNull);

    expect(find.byTooltip('Copiar UUID completo'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Avanzado'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Avanzado'));
    await tester.pumpAndSettle();
    expect(find.text('FakeSyncBackendAdapter'), findsOneWidget);
    expect(find.text('30 s'), findsOneWidget);
    expect(find.text('{"markers":{"uuid":"cursor"}}'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpAtSize(
      tester,
      const Size(1440, 900),
      SynchronizationScreen(service: service, pairingService: pairingService),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Subidas pendientes'), findsOneWidget);
    expect(find.text('Conectado'), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.dispose();
    pairingService.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });

  testWidgets('clearing the local queue always requires confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final connectivity = ConnectivityService();
    final queue = PersistentSyncQueue(storageKey: 'test.sync.clear.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    await queue.enqueue(
      SyncOperation(
        uuid: '22222222-2222-4222-8222-222222222222',
        entityType: SyncEntityType.favorite,
        operationType: SyncOperationType.delete,
        createdAt: DateTime.utc(2026, 7, 15),
        retryCount: 0,
        payloadReference: 'favorite:test',
      ),
    );
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      synchronizeAction: () async => false,
      deviceDetailsLoader: () async => const SynchronizationDeviceDetails(
        name: 'Android',
        uuid: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        appVersion: '1.0.1',
        platform: 'Android',
      ),
    );
    await _pumpAtSize(
      tester,
      const Size(390, 844),
      SynchronizationScreen(service: service),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.scrollUntilVisible(
      find.text('Limpiar cola local'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Limpiar cola local'));
    await tester.pumpAndSettle();
    expect(find.text('¿Limpiar cambios pendientes?'), findsOneWidget);
    expect(await queue.readAll(), hasLength(1));

    await tester.tap(find.text('Limpiar cola'));
    await tester.pumpAndSettle();
    expect(await queue.readAll(), isEmpty);

    service.dispose();
    await engine.dispose();
    await connectivity.dispose();
  });
}

DevicePairingService _pairingService({
  bool withPeer = false,
  _FakePairingBackend? backend,
}) {
  backend ??= _FakePairingBackend();
  if (withPeer) {
    backend.devices = [
      ...backend.devices,
      PairedDevice(
        deviceUuid: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        deviceName: 'Escritorio de campo',
        platform: 'Windows',
        pairedAt: _FakePairingBackend._createdAt,
      ),
    ];
  }
  return DevicePairingService(
    backend: backend,
    registrationLoader: () async => const PairingDeviceRegistration(
      deviceUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      deviceName: 'Dispositivo de prueba',
      platform: 'Android',
    ),
  );
}

class _FakePairingBackend implements DevicePairingBackend {
  static final _createdAt = DateTime.utc(2026, 7, 15, 14);

  final _group = SyncGroup(
    groupUuid: '99999999-9999-4999-8999-999999999999',
    ownerDeviceUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    createdAt: _createdAt,
  );

  @override
  bool get isConfigured => true;

  List<PairedDevice> devices = [
    PairedDevice(
      deviceUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      deviceName: 'Dispositivo de prueba',
      platform: 'Android',
      pairedAt: _createdAt,
      lastSynchronizationAt: _createdAt,
      isCurrentDevice: true,
    ),
  ];

  @override
  Future<PairingClaimResult> claimPairingToken({
    required PairingDeviceRegistration registration,
    String? token,
    String? pairingCode,
  }) async => PairingClaimResult(group: _group, devices: devices);

  @override
  Future<PairingSession> createPairingSession(
    PairingDeviceRegistration registration,
  ) async => PairingSession(
    token: 'secure-one-time-token',
    pairingCode: '482913',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  );

  @override
  Future<List<PairedDevice>> listDevices(String currentDeviceUuid) async =>
      devices;

  @override
  Future<PairingBootstrapResult> registerCurrentDevice(
    PairingDeviceRegistration registration,
  ) async => PairingBootstrapResult(group: _group, devices: devices);

  @override
  Future<void> removeDevice({
    required String deviceUuid,
    required String currentDeviceUuid,
  }) async {
    devices = devices
        .where((device) => device.deviceUuid != deviceUuid)
        .toList();
  }

  @override
  Future<PairedDevice> renameDevice({
    required String deviceUuid,
    required String deviceName,
    required String currentDeviceUuid,
  }) async {
    final current = devices.firstWhere(
      (device) => device.deviceUuid == deviceUuid,
    );
    final updated = current.copyWith(deviceName: deviceName);
    devices = [
      for (final device in devices)
        if (device.deviceUuid == deviceUuid) updated else device,
    ];
    return updated;
  }
}

class _ExpiringPairingBackend extends _FakePairingBackend {
  int createSessionCalls = 0;

  @override
  Future<PairingSession> createPairingSession(
    PairingDeviceRegistration registration,
  ) async {
    createSessionCalls++;
    return PairingSession(
      token: 'secure-token-$createSessionCalls',
      pairingCode: createSessionCalls == 1 ? '111111' : '222222',
      expiresAt: createSessionCalls == 1
          ? DateTime.now().add(const Duration(milliseconds: 100))
          : DateTime.now().add(const Duration(minutes: 5)),
    );
  }
}

Future<void> _pumpAtSize(WidgetTester tester, Size size, Widget screen) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: screen));
}
