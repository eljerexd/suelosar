import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/app/app_routes.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/screens/synchronization_screen.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/synchronization_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_coordinator.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_operation.dart';
import 'package:suelosar/sync/sync_status.dart';

void main() {
  testWidgets('Linked status opens summary before the existing details route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(deviceLinkedStatusLoader: () async => true),
        onGenerateRoute: (settings) {
          if (settings.name != AppRoutes.synchronization) return null;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('SYNC_LINKED')),
          );
        },
      ),
    );

    final syncStatus = find.byKey(
      const ValueKey('home-synchronization-status'),
    );
    await tester.pump();
    await tester.tap(syncStatus);
    await tester.pumpAndSettle();

    expect(find.text('Dispositivos vinculados'), findsOneWidget);
    expect(find.text('SYNC_LINKED'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Ver detalles'));
    await tester.pumpAndSettle();
    expect(find.text('SYNC_LINKED'), findsOneWidget);
  });

  testWidgets('Unlinked status offers the existing pairing flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(deviceLinkedStatusLoader: () async => false),
      ),
    );

    final syncStatus = find.byKey(
      const ValueKey('home-synchronization-status'),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: syncStatus,
        matching: find.byIcon(Icons.link_off_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(syncStatus);
    await tester.pumpAndSettle();
    expect(
      find.text('Protegé tus datos sincronizando tus dispositivos.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Agregar dispositivo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final screen = tester.widget<SynchronizationScreen>(
      find.byType(SynchronizationScreen),
    );
    expect(screen.openPairingOnStart, isTrue);
  });

  testWidgets('Synchronization status preserves the original Home grid', (
    tester,
  ) async {
    for (final size in const [Size(390, 844), Size(1400, 900)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(deviceLinkedStatusLoader: () async => true),
        ),
      );
      final soilCard = find.byKey(const ValueKey('module-soil-maps'));
      final markerCard = find.byKey(const ValueKey('module-personal-markers'));
      final settingsCard = find.byKey(const ValueKey('module-settings'));
      await tester.ensureVisible(settingsCard);
      expect(
        find.byKey(const ValueKey('module-synchronization')),
        findsNothing,
      );
      expect(find.byType(AppBar), findsNothing);
      expect(tester.getSize(soilCard).width, tester.getSize(markerCard).width);
      expect(
        tester.getSize(markerCard).width,
        tester.getSize(settingsCard).width,
      );
      if (size.width >= 620) {
        expect(
          tester.getTopLeft(soilCard).dy,
          tester.getTopLeft(markerCard).dy,
        );
        expect(
          tester.getTopLeft(settingsCard).dy,
          greaterThan(tester.getTopLeft(markerCard).dy),
        );
        expect(
          tester.getTopLeft(settingsCard).dx,
          tester.getTopLeft(soilCard).dx,
        );
      }
      expect(tester.takeException(), isNull);
    }
    tester.view.reset();
  });

  testWidgets('Sync status reflects live synchronization states', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{
      SyncCoordinator.lastSuccessfulSyncStorageKey: DateTime.now()
          .subtract(const Duration(minutes: 3))
          .toUtc()
          .toIso8601String(),
    });
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.home.sync.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    for (var index = 0; index < 5; index++) {
      await queue.enqueue(
        SyncOperation(
          uuid: '00000000-0000-4000-8000-00000000000$index',
          entityType: SyncEntityType.marker,
          operationType: SyncOperationType.create,
          createdAt: DateTime.now().toUtc(),
          retryCount: 0,
          payloadReference: 'marker-$index',
        ),
      );
    }
    final service = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      deviceDetailsLoader: () async =>
          const SynchronizationDeviceDetails.empty(),
    );
    engine.status.value = SyncStatus.uploading;

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => true,
          synchronizationService: service,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final syncStatus = find.byKey(
      const ValueKey('home-synchronization-status'),
    );
    expect(
      find.descendant(
        of: syncStatus,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('Sincronizando…'), findsOneWidget);

    engine.status.value = SyncStatus.queued;
    await service.refresh();
    await tester.pump();
    expect(find.text('5 pendientes'), findsOneWidget);

    connectivity.update(ConnectivityStatus.offline);
    await tester.pump();
    expect(find.text('Sin conexión'), findsOneWidget);
    connectivity.update(ConnectivityStatus.online);

    engine.status.value = SyncStatus.error;
    await tester.pump();
    expect(find.text('Error de sincronización'), findsOneWidget);

    await queue.removeAll(
      (await queue.readAll()).map((operation) => operation.operationId),
    );
    await service.refresh();
    engine.status.value = SyncStatus.completed;
    await tester.pump();
    expect(find.text('Sincronizado'), findsOneWidget);
    await tester.tap(syncStatus);
    await tester.pumpAndSettle();
    expect(find.text('hace 3 min'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await engine.dispose();
  });

  testWidgets('Windows status uses an anchored Material menu', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(deviceLinkedStatusLoader: () async => false),
      ),
    );
    await tester.pump();

    final status = find.byKey(const ValueKey('home-synchronization-status'));
    await tester.tap(status);
    await tester.pumpAndSettle();

    expect(find.byType(MenuAnchor), findsOneWidget);
    expect(
      find.text('Protegé tus datos sincronizando tus dispositivos.'),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
  });
}
