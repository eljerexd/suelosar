import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/constants/app_icons.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';
import 'package:suelosar/gis/province_config.dart';
import 'package:suelosar/gis/widgets/province_download_map_overlay.dart';
import 'package:suelosar/services/settings_service.dart';

void main() {
  late _FakeDelivery buenosAires;
  late _FakeDelivery santaFe;
  late _FakeDelivery cordoba;
  late ValueNotifier<int> cameraChanges;
  late Map<String, Offset> projectedAnchors;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.initialize();
    buenosAires = _FakeDelivery();
    santaFe = _FakeDelivery();
    cordoba = _FakeDelivery();
    cameraChanges = ValueNotifier(0);
    projectedAnchors = {
      'buenos_aires': const Offset(430, 470),
      'santa_fe': const Offset(570, 200),
      'cordoba': const Offset(370, 330),
    };
  });

  tearDown(() => cameraChanges.dispose());

  List<ProvinceDownloadMapItem> makeItems() => [
    ProvinceDownloadMapItem(
      id: 'buenos_aires',
      name: 'Buenos Aires',
      resolveScreenPosition: () => projectedAnchors['buenos_aires'],
      sizeBytes: 158646380,
      metadata: ProvinceConfig.buenosAires.downloadMetadata,
      delivery: buenosAires,
      onDownload: buenosAires.download,
    ),
    ProvinceDownloadMapItem(
      id: 'santa_fe',
      name: 'Santa Fe',
      resolveScreenPosition: () => projectedAnchors['santa_fe'],
      sizeBytes: 65985455,
      metadata: ProvinceConfig.santaFe.downloadMetadata,
      delivery: santaFe,
      onDownload: santaFe.download,
    ),
    ProvinceDownloadMapItem(
      id: 'cordoba',
      name: 'Córdoba',
      resolveScreenPosition: () => projectedAnchors['cordoba'],
      sizeBytes: 77400595,
      metadata: ProvinceConfig.cordoba.downloadMetadata,
      delivery: cordoba,
      onDownload: cordoba.download,
    ),
  ];

  Widget buildOverlay(
    List<ProvinceDownloadMapItem> items, {
    void Function(String id, PmtilesDeliveryStatus status)? onDismiss,
    bool mapFrameSynchronized = false,
    double topOverlayClearance = 204,
  }) => ProvinceDownloadMapOverlay(
    items: items,
    cameraChanges: cameraChanges,
    mapFrameSynchronized: mapFrameSynchronized,
    topOverlayClearance: topOverlayClearance,
    onDismiss: onDismiss ?? (_, _) {},
  );

  testWidgets('renders compact indicators without the old instruction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    expect(
      find.text('Seleccioná una provincia para ver las opciones de descarga'),
      findsNothing,
    );
    expect(find.text('Buenos Aires'), findsOneWidget);
    expect(find.text('Santa Fe'), findsOneWidget);
    expect(find.text('Córdoba'), findsOneWidget);
    expect(find.text('151.3 MB'), findsOneWidget);
    expect(find.text('62.9 MB'), findsOneWidget);
    expect(find.text('73.8 MB'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(3));
    expect(find.byIcon(AppIcons.close), findsNothing);
    expect(find.byIcon(AppIcons.downloadArrow), findsNothing);
    expect(find.text('Descargar mapas'), findsNothing);
  });

  test('province download metadata is preserved in configuration', () {
    expect(
      ProvinceConfig.buenosAires.downloadMetadata.description,
      'Cartografía de suelos y polígonos',
    );
    expect(
      ProvinceConfig.santaFe.downloadMetadata.description,
      'Cartografía de suelos y polígonos',
    );
    expect(
      ProvinceConfig.cordoba.downloadMetadata.description,
      'Cartografía de suelos y polígonos',
    );
    expect(ProvinceConfig.buenosAires.downloadMetadata.sourceLines, [
      'Escala de origen: 1:50.000',
    ]);
    expect(ProvinceConfig.santaFe.downloadMetadata.sourceLines, [
      'Fuente: INTA (GeoJSON)',
    ]);
    expect(ProvinceConfig.cordoba.downloadMetadata.sourceLines, [
      'Escalas: 1:50.000 · 1:100.000',
      'Cobertura residual: 1:500.000',
    ]);
  });

  testWidgets('expanded province cards show the same minimal information', (
    tester,
  ) async {
    final cases = [
      (id: 'buenos_aires', name: 'Buenos Aires', size: '151.3 MB'),
      (id: 'santa_fe', name: 'Santa Fe', size: '62.9 MB'),
      (id: 'cordoba', name: 'Córdoba', size: '73.8 MB'),
    ];

    for (final itemCase in cases) {
      final item = makeItems().firstWhere((item) => item.id == itemCase.id);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildOverlay([item]))),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('province-download-indicator-${itemCase.id}')),
      );
      await tester.pumpAndSettle();

      expect(find.text(itemCase.name), findsWidgets);
      expect(find.text(itemCase.size), findsOneWidget);
      expect(find.text('Cartografía de suelos'), findsOneWidget);
      expect(find.text('Sin conexión tras la descarga'), findsOneWidget);
      expect(find.text('Descargar'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('province-download-metadata')),
        findsNothing,
      );
      expect(find.textContaining('Cobertura:'), findsNothing);
      expect(find.textContaining('Escala'), findsNothing);
      expect(find.textContaining('Fuente:'), findsNothing);
      expect(find.textContaining('residual'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('first map display animates only the chevrons and then stops', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.pump();
    await tester.pump();

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool('onboarding.province_indicator_chevron_hint_shown'),
      isTrue,
    );
    expect(find.text('Cartografía de suelos'), findsNothing);

    final pillRects = {
      for (final id in ['buenos_aires', 'santa_fe', 'cordoba'])
        id: tester.getRect(find.byKey(ValueKey('province-download-card-$id'))),
    };
    await tester.pump(const Duration(milliseconds: 200));
    final offsetsDuringHint = {
      for (final id in ['buenos_aires', 'santa_fe', 'cordoba'])
        id: tester
            .widget<Transform>(
              find.byKey(ValueKey('province-chevron-motion-$id')),
            )
            .transform
            .getTranslation()
            .y,
    };
    expect(offsetsDuringHint.values, everyElement(greaterThan(0)));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.keyboard_arrow_down).first).weight,
      700,
    );
    for (final entry in pillRects.entries) {
      expect(
        tester.getRect(
          find.byKey(ValueKey('province-download-card-${entry.key}')),
        ),
        entry.value,
      );
    }
    expect(find.text('Cartografía de suelos'), findsNothing);

    cameraChanges.value++;
    await tester.pump(const Duration(milliseconds: 70));
    final offsetsAfterCameraRebuild = {
      for (final id in ['buenos_aires', 'santa_fe', 'cordoba'])
        id: tester
            .widget<Transform>(
              find.byKey(ValueKey('province-chevron-motion-$id')),
            )
            .transform
            .getTranslation()
            .y,
    };
    for (final id in offsetsDuringHint.keys) {
      expect(
        offsetsAfterCameraRebuild[id],
        greaterThan(offsetsDuringHint[id]!),
      );
      expect(offsetsAfterCameraRebuild[id], greaterThan(7.0));
      expect(
        tester.getRect(find.byKey(ValueKey('province-download-card-$id'))),
        pillRects[id],
      );
    }

    double santaFeChevronOffset() => tester
        .widget<Transform>(
          find.byKey(const ValueKey('province-chevron-motion-santa_fe')),
        )
        .transform
        .getTranslation()
        .y;

    Future<void> expectPillsStationary() async {
      for (final entry in pillRects.entries) {
        expect(
          tester.getRect(
            find.byKey(ValueKey('province-download-card-${entry.key}')),
          ),
          entry.value,
        );
      }
    }

    await tester.pump(const Duration(milliseconds: 380));
    expect(santaFeChevronOffset(), closeTo(0, 0.01));
    await expectPillsStationary();

    await tester.pump(const Duration(milliseconds: 381));
    expect(santaFeChevronOffset(), greaterThan(7.0));
    await expectPillsStationary();

    await tester.pump(const Duration(milliseconds: 369));
    expect(santaFeChevronOffset(), closeTo(0, 0.01));
    await expectPillsStationary();

    await tester.pump(const Duration(milliseconds: 381));
    expect(santaFeChevronOffset(), greaterThan(7.0));
    await expectPillsStationary();

    await tester.pump(const Duration(milliseconds: 469));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('province-chevron-motion-santa_fe')),
          )
          .transform
          .getTranslation()
          .y,
      closeTo(0, 0.01),
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.keyboard_arrow_down).first).weight,
      isNull,
    );
    expect(find.text('Cartografía de suelos'), findsNothing);
  });

  testWidgets('waits until a province indicator is actually visible', (
    tester,
  ) async {
    projectedAnchors = {
      'buenos_aires': const Offset(900, 900),
      'santa_fe': const Offset(-900, -900),
      'cordoba': const Offset(900, -900),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.pump();
    await tester.pump();

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool('onboarding.province_indicator_chevron_hint_shown'),
      isNull,
    );
    expect(find.text('Cartografía de suelos'), findsNothing);

    projectedAnchors['santa_fe'] = const Offset(252, 256);
    cameraChanges.value++;
    await tester.pump();
    await tester.pump();
    expect(
      preferences.getBool('onboarding.province_indicator_chevron_hint_shown'),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('province-chevron-motion-santa_fe')),
          )
          .transform
          .getTranslation()
          .y,
      greaterThan(0),
    );
    expect(find.text('Cartografía de suelos'), findsNothing);
  });

  testWidgets('indicator remains tappable while the discovery hint runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('province-download-card-santa_fe')),
      findsOneWidget,
    );
    expect(find.text('Cartografía de suelos'), findsOneWidget);
  });

  testWidgets('completed hint does not replay after map overlay reopens', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('province-chevron-motion-santa_fe')),
          )
          .transform
          .getTranslation()
          .y,
      0,
    );
  });

  testWidgets('reduce animations skips and permanently completes the hint', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'settings.reduce_animations': true,
    });
    await SettingsService.instance.initialize();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool('onboarding.province_indicator_chevron_hint_shown'),
      isTrue,
    );
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('province-chevron-motion-santa_fe')),
          )
          .transform
          .getTranslation()
          .y,
      0,
    );
  });

  testWidgets('whole indicator selects and switches the single shared card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-buenos_aires')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cartografía de suelos'), findsOneWidget);
    expect(find.text('Buenos Aires').last, findsOneWidget);
    expect(
      find.byKey(const ValueKey('province-download-card-buenos_aires')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-cordoba')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('province-download-card-cordoba')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('province-download-card-title-cordoba')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('province-download-card-santa_fe')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));
    expect(find.byIcon(AppIcons.close), findsOneWidget);
    final close = find.byKey(
      const ValueKey('province-download-card-close-cordoba'),
    );
    expect(tester.getSize(close), const Size(40, 40));
    final headerRect = tester.getRect(
      find.byKey(const ValueKey('province-download-header-cordoba')),
    );
    expect(headerRect.center.dx, closeTo(355, 1));
    expect(headerRect.center.dy, closeTo(330, 2));
  });

  testWidgets('close collapses the shared card and records province status', (
    tester,
  ) async {
    String? dismissedId;
    PmtilesDeliveryStatus? dismissedStatus;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildOverlay(
            makeItems(),
            onDismiss: (id, status) {
              dismissedId = id;
              dismissedStatus = status;
            },
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('province-download-card-close-santa_fe')),
    );
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('province-download-card-santa_fe')),
      findsOneWidget,
    );
    expect(dismissedId, 'santa_fe');
    expect(dismissedStatus, PmtilesDeliveryStatus.notInstalled);
    expect(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(3));
  });

  testWidgets('download button stays compact and invokes original callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-buenos_aires')),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('province-download-action'));
    expect(find.text('Descargar'), findsOneWidget);
    expect(find.text('Descargar mapas'), findsNothing);
    expect(tester.getSize(action), const Size(130, 36));
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('province-download-card-buenos_aires')),
    );
    final actionRect = tester.getRect(action);
    expect(actionRect.right, lessThanOrEqualTo(cardRect.right - 8));
    expect(actionRect.center.dx, closeTo(cardRect.center.dx, 2));
    await tester.tap(action);
    expect(buenosAires.downloadCalls, 1);
    expect(santaFe.downloadCalls, 0);
    expect(cordoba.downloadCalls, 0);
  });

  testWidgets('error keeps the minimal card and retry uses the same callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
    );
    await tester.pumpAndSettle();

    santaFe.reportError();
    await tester.pumpAndSettle();
    expect(find.text('No se pudo completar la descarga'), findsNothing);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('Descargar'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('province-download-action')));
    await tester.pump();
    expect(santaFe.downloadCalls, 1);
    expect(find.text('Descargando mapas...'), findsOneWidget);
  });

  testWidgets('shows actual determinate percentage and byte counts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-cordoba')),
    );
    cordoba.reportIndeterminate();
    await tester.pump();
    expect(find.text('Descargando mapas...'), findsOneWidget);
    for (final percent in [20, 42, 75, 100]) {
      cordoba.reportProgress(percent * 1024 * 1024, 100 * 1024 * 1024);
      await tester.pump();

      expect(find.text('$percent%'), findsOneWidget);
      expect(
        find.text('${percent.toStringAsFixed(1)} MB / 100.0 MB'),
        findsOneWidget,
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('province-download-linear-progress')),
      );
      expect(bar.value, percent / 100);
      if (percent == 100) {
        expect(
          find.byKey(const ValueKey('province-download-success')),
          findsNothing,
        );
      }
    }
  });

  testWidgets(
    'download stage width expands then contracts through completion',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      projectedAnchors = {
        'buenos_aires': const Offset(210, 650),
        'santa_fe': const Offset(250, 250),
        'cordoba': const Offset(170, 420),
      };
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
      );
      await tester.tap(
        find.byKey(const ValueKey('province-download-indicator-cordoba')),
      );
      await tester.pumpAndSettle();

      final stage = find.byKey(
        const ValueKey('province-download-stage-container'),
      );
      final buttonWidth = tester.getSize(stage).width;
      expect(buttonWidth, closeTo(130, 1));
      await tester.tap(find.byKey(const ValueKey('province-download-action')));
      expect(cordoba.downloadCalls, 1);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('province-download-linear-progress')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 110));
      final expandingWidth = tester.getSize(stage).width;
      expect(expandingWidth, greaterThan(buttonWidth + 20));

      await tester.pump(const Duration(milliseconds: 360));
      final progressWidth = tester.getSize(stage).width;
      expect(progressWidth, greaterThan(expandingWidth));
      expect(progressWidth, greaterThan(buttonWidth + 40));

      cordoba.reportProgress(100, 100);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('province-download-success')),
        findsNothing,
      );
      cordoba.reportAvailable();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final contractingWidth = tester.getSize(stage).width;
      expect(contractingWidth, lessThan(progressWidth));
      expect(contractingWidth, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 320));
      final successWidth = tester.getSize(stage).width;
      expect(successWidth, lessThan(progressWidth));
      expect(
        find.byKey(const ValueKey('province-download-success')),
        findsOneWidget,
      );
    },
  );

  testWidgets('keeps progress indeterminate without a reported total', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-cordoba')),
    );
    cordoba.reportIndeterminate();
    await tester.pump();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('province-download-linear-progress')),
    );
    expect(bar.value, isNull);
    expect(
      find.byKey(const ValueKey('province-download-percent')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('province-download-byte-label')),
      findsNothing,
    );
  });

  testWidgets('available status drives success then automatic dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-buenos_aires')),
    );
    await tester.pumpAndSettle();
    buenosAires.reportIndeterminate();
    buenosAires.reportAvailable();
    await tester.pump();

    expect(find.text('Disponible offline'), findsOneWidget);
    expect(find.byIcon(AppIcons.check), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 620));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('province-download-card-santa_fe')),
          )
          .height,
      inInclusiveRange(42, 46),
    );
    expect(find.text('Disponible offline'), findsNothing);
  });

  testWidgets(
    'download progress continues while another province is selected',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
      );
      await tester.tap(
        find.byKey(const ValueKey('province-download-indicator-buenos_aires')),
      );
      buenosAires.reportProgress(20, 100);
      await tester.pumpAndSettle();
      expect(find.text('20%'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('province-download-indicator-santa_fe')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Santa Fe').last, findsOneWidget);

      buenosAires.reportProgress(75, 100);
      await tester.pumpAndSettle();
      expect(find.text('Santa Fe').last, findsOneWidget);
      expect(find.text('75%'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('province-download-indicator-buenos_aires')),
      );
      await tester.pumpAndSettle();
      expect(find.text('75%'), findsOneWidget);
    },
  );

  testWidgets('all province indicators follow their geographic anchors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    final items = makeItems();

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(items))),
    );
    await tester.pumpAndSettle();
    final keys = [
      const ValueKey('province-download-indicator-santa_fe'),
      const ValueKey('province-download-indicator-cordoba'),
      const ValueKey('province-download-indicator-buenos_aires'),
    ];
    final before = [
      for (final key in keys) tester.getRect(find.byKey(key)).center,
    ];
    const cameraDelta = Offset(18, -24);
    projectedAnchors.updateAll((_, position) => position + cameraDelta);
    cameraChanges.value++;
    await tester.pump();
    final after = [
      for (final key in keys) tester.getRect(find.byKey(key)).center,
    ];
    for (var index = 0; index < before.length; index++) {
      expect(after[index].dx, closeTo(before[index].dx + cameraDelta.dx, 0.01));
      expect(after[index].dy, closeTo(before[index].dy + cameraDelta.dy, 0.01));
    }
  });

  testWidgets('all three indicators track repeated camera movement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    final originalAnchors = Map<String, Offset>.of(projectedAnchors);
    final originalCenters = [
      for (final id in ['buenos_aires', 'santa_fe', 'cordoba'])
        tester
            .getRect(find.byKey(ValueKey('province-download-card-$id')))
            .center,
    ];
    final ids = ['buenos_aires', 'santa_fe', 'cordoba'];

    for (var step = 1; step <= 4; step++) {
      final delta = Offset(step * 3, step * -2);
      projectedAnchors = {
        for (final entry in originalAnchors.entries)
          entry.key: entry.value + delta,
      };
      cameraChanges.value++;
      await tester.pump();
      for (var index = 0; index < ids.length; index++) {
        final center = tester
            .getRect(
              find.byKey(ValueKey('province-download-card-${ids[index]}')),
            )
            .center;
        expect(center.dx, closeTo(originalCenters[index].dx + delta.dx, 0.01));
        expect(center.dy, closeTo(originalCenters[index].dy + delta.dy, 0.01));
      }
    }
  });

  testWidgets('map-frame updates keep all indicators geographically anchored', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    late StateSetter rebuildMapFrame;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuildMapFrame = setState;
              return buildOverlay(makeItems(), mapFrameSynchronized: true);
            },
          ),
        ),
      ),
    );

    final ids = ['buenos_aires', 'santa_fe', 'cordoba'];
    final originalCenters = [
      for (final id in ids)
        tester
            .getRect(find.byKey(ValueKey('province-download-card-$id')))
            .center,
    ];
    const cameraDelta = Offset(-31, 22);
    projectedAnchors.updateAll((_, anchor) => anchor + cameraDelta);
    rebuildMapFrame(() {});
    await tester.pump();

    for (var index = 0; index < ids.length; index++) {
      final center = tester
          .getRect(find.byKey(ValueKey('province-download-card-${ids[index]}')))
          .center;
      expect(
        center.dx,
        closeTo(originalCenters[index].dx + cameraDelta.dx, 0.01),
      );
      expect(
        center.dy,
        closeTo(originalCenters[index].dy + cameraDelta.dy, 0.01),
      );
    }
  });

  testWidgets('all three indicators render when their anchors are on-screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(190, 180),
      'cordoba': const Offset(166, 384),
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildOverlay(
            makeItems(),
            mapFrameSynchronized: true,
            topOverlayClearance: 154,
          ),
        ),
      ),
    );

    for (final id in ['buenos_aires', 'santa_fe', 'cordoba']) {
      final indicator = find.byKey(ValueKey('province-download-indicator-$id'));
      expect(indicator, findsOneWidget, reason: '$id anchor is on-screen');
      final opacity = find.ancestor(
        of: indicator,
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(opacity.first).opacity, 1);
    }
  });

  testWidgets('compact pills use intrinsic phone-width sizing', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(220, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    final santaFe = tester.getSize(
      find.byKey(const ValueKey('province-download-card-santa_fe')),
    );
    final cordoba = tester.getSize(
      find.byKey(const ValueKey('province-download-card-cordoba')),
    );
    final buenosAires = tester.getSize(
      find.byKey(const ValueKey('province-download-card-buenos_aires')),
    );
    final locationPin = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('province-download-card-cordoba')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Icon && widget.icon == AppIcons.location,
        ),
      ),
    );
    expect(locationPin.size, 19);
    expect(santaFe.height, inInclusiveRange(42, 46));
    expect(cordoba.height, inInclusiveRange(42, 46));
    expect(buenosAires.height, inInclusiveRange(42, 46));
    expect(santaFe.width, lessThan(220));
    expect(cordoba.width, lessThan(220));
    expect(buenosAires.width, lessThanOrEqualTo(240));
    expect(buenosAires.width, greaterThan(santaFe.width));
    for (final id in ['santa_fe', 'cordoba', 'buenos_aires']) {
      final title = find.byKey(ValueKey('province-download-card-title-$id'));
      final titleParagraph = tester.renderObject<RenderParagraph>(title);
      final sizeParagraph = tester.renderObject<RenderParagraph>(
        find.byKey(ValueKey('province-download-card-size-$id')),
      );
      expect(titleParagraph.didExceedMaxLines, isFalse);
      expect(sizeParagraph.didExceedMaxLines, isFalse);
      expect(
        titleParagraph.size.width + 0.1,
        greaterThanOrEqualTo(
          titleParagraph.getMaxIntrinsicWidth(double.infinity),
        ),
        reason: 'The compact $id indicator must show its full province name.',
      );
      expect(
        tester
            .getTopLeft(find.byKey(ValueKey('province-download-card-$id')))
            .dx,
        greaterThanOrEqualTo(0),
      );
      expect(
        tester
            .getBottomRight(find.byKey(ValueKey('province-download-card-$id')))
            .dx,
        lessThanOrEqualTo(360),
      );
    }
  });

  testWidgets('compact province names stay complete with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(220, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.1)),
            child: Scaffold(body: buildOverlay(makeItems())),
          ),
        ),
      ),
    );

    for (final id in ['santa_fe', 'cordoba', 'buenos_aires']) {
      final title = tester.renderObject<RenderParagraph>(
        find.byKey(ValueKey('province-download-card-title-$id')),
      );
      expect(
        title.didExceedMaxLines,
        isFalse,
        reason: '$id should retain its complete name at larger text scale.',
      );
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.byKey(ValueKey('province-download-card-size-$id')),
            )
            .didExceedMaxLines,
        isFalse,
        reason: '$id should retain its complete size at larger text scale.',
      );
      final card = tester.getRect(
        find.byKey(ValueKey('province-download-card-$id')),
      );
      expect(card.left, greaterThanOrEqualTo(0));
      expect(card.right, lessThanOrEqualTo(360));
    }
  });

  testWidgets('compact province labels fit a narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(146, 560),
      'santa_fe': const Offset(121, 220),
      'cordoba': const Offset(175, 380),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: Scaffold(body: buildOverlay(makeItems())),
          ),
        ),
      ),
    );

    for (final id in ['santa_fe', 'cordoba', 'buenos_aires']) {
      final card = find.byKey(ValueKey('province-download-card-$id'));
      final title = tester.renderObject<RenderParagraph>(
        find.byKey(ValueKey('province-download-card-title-$id')),
      );
      final size = tester.renderObject<RenderParagraph>(
        find.byKey(ValueKey('province-download-card-size-$id')),
      );
      expect(
        title.didExceedMaxLines,
        isFalse,
        reason:
            '$id title clipped: width=${title.size.width}, intrinsic=${title.getMaxIntrinsicWidth(double.infinity)}, card=${tester.getSize(card)}.',
      );
      expect(size.didExceedMaxLines, isFalse, reason: '$id size clipped.');
      expect(tester.getRect(card).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(card).right, lessThanOrEqualTo(320));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone indicators stay centered on projected province anchors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(426.667, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    const expected = {
      'santa_fe': Offset(291, 256),
      'cordoba': Offset(151, 384),
      'buenos_aires': Offset(216, 620),
    };
    for (final entry in expected.entries) {
      final rect = tester.getRect(
        find.byKey(ValueKey('province-download-card-${entry.key}')),
      );
      expect(rect.center.dx, closeTo(entry.value.dx, 1));
      expect(rect.center.dy, closeTo(entry.value.dy, 1));
      expect(rect.left, greaterThan(12));
      expect(rect.right, lessThanOrEqualTo(410.667));
    }
  });

  testWidgets('expanded card follows its province while panning', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-cordoba')),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('province-download-card-cordoba'));
    final originalSize = tester.getSize(card);
    final originalCardLeft = tester.getRect(card).left;
    final originalHeader = tester.getRect(
      find.byKey(const ValueKey('province-download-header-cordoba')),
    );
    expect(originalHeader.center.dx, closeTo(151, 2));
    expect(originalHeader.center.dy, closeTo(384, 2));

    projectedAnchors['cordoba'] = const Offset(243, 584);
    cameraChanges.value++;
    await tester.pump();
    await tester.pumpAndSettle();

    final pannedHeader = tester.getRect(
      find.byKey(const ValueKey('province-download-header-cordoba')),
    );
    expect(pannedHeader.center.dx, closeTo(228, 2));
    expect(pannedHeader.center.dy, closeTo(584, 2));
    expect(tester.getSize(card).width, originalSize.width);
    expect(tester.getSize(card).height, closeTo(originalSize.height, 0.01));
    expect(tester.getRect(card).left, closeTo(originalCardLeft + 77, 1));
    final edgeOpacityFinder = find.ancestor(
      of: card,
      matching: find.byType(Opacity),
    );
    expect(
      tester.widget<Opacity>(edgeOpacityFinder.first).opacity,
      closeTo(0.875, 0.02),
    );

    projectedAnchors['cordoba'] = const Offset(287, 584);
    cameraChanges.value++;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.getRect(card).left, closeTo(originalCardLeft + 121, 1));
    expect(tester.getSize(card).width, originalSize.width);
    expect(
      tester.widget<Opacity>(edgeOpacityFinder.first).opacity,
      closeTo(0.0892857, 0.02),
    );
  });

  testWidgets('card expansion and collapse preserve their anchor and sizes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    final card = find.byKey(const ValueKey('province-download-card-cordoba'));
    final compactRect = tester.getRect(card);
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-cordoba')),
    );
    await tester.pumpAndSettle();
    final expandedRect = tester.getRect(card);
    final title = find.byKey(
      const ValueKey('province-download-card-title-cordoba'),
    );
    final expandedTitleRect = tester.getRect(title);
    expect(expandedRect.width, greaterThan(compactRect.width));
    expect(expandedRect.height, greaterThan(compactRect.height));
    expect(expandedRect.center.dx, closeTo(151, 2));

    await tester.tap(
      find.byKey(const ValueKey('province-download-card-close-cordoba')),
    );
    await tester.pump(Duration.zero);
    final firstCollapseRect = tester.getRect(card);
    final firstCollapseTitleRect = tester.getRect(title);
    expect(firstCollapseRect.center.dx, closeTo(expandedRect.center.dx, 1));
    expect(firstCollapseTitleRect.left, closeTo(expandedTitleRect.left, 1));
    expect(firstCollapseTitleRect.top, closeTo(expandedTitleRect.top, 1));
    expect(
      firstCollapseRect.top,
      inInclusiveRange(expandedRect.top - 1, compactRect.top + 1),
    );
    final cardFade = find.ancestor(
      of: card,
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(cardFade.first).opacity, 1);
    final collapseHeights = <double>[];
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 75));
      collapseHeights.add(tester.getRect(card).height);
      expect(
        tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
        isFalse,
        reason:
            'Province title clipped during collapse frame $frame; '
            'card=${tester.getSize(card)}, '
            'title=${tester.renderObject<RenderParagraph>(title).size}, '
            'natural=${tester.renderObject<RenderParagraph>(title).getMaxIntrinsicWidth(double.infinity)}.',
      );
    }
    expect(collapseHeights[0], lessThan(expandedRect.height));
    expect(collapseHeights[1], lessThan(collapseHeights[0]));
    expect(collapseHeights[2], lessThan(collapseHeights[1]));
    expect(collapseHeights[3], lessThan(collapseHeights[2]));
    final midCollapseRect = tester.getRect(card);
    expect(midCollapseRect.center.dx, closeTo(expandedRect.center.dx, 1));
    expect(
      midCollapseRect.top,
      inInclusiveRange(expandedRect.top - 2, compactRect.top + 2),
    );
    expect(
      find.byKey(const ValueKey('province-download-card-close-cordoba')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pumpAndSettle();
    final collapsedRect = tester.getRect(card);
    expect(collapsedRect.width, closeTo(compactRect.width, 1));
    expect(collapsedRect.height, closeTo(compactRect.height, 1));
    expect(collapsedRect.top, closeTo(compactRect.top, 1));
    expect(collapsedRect.center.dx, closeTo(151, 2));
  });

  testWidgets(
    'card content follows one expansion timeline in both directions',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      projectedAnchors = {
        'buenos_aires': const Offset(202, 620),
        'santa_fe': const Offset(252, 256),
        'cordoba': const Offset(166, 384),
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.1)),
              child: Scaffold(body: buildOverlay(makeItems())),
            ),
          ),
        ),
      );

      for (final id in ['santa_fe', 'cordoba', 'buenos_aires']) {
        final card = find.byKey(ValueKey('province-download-card-$id'));
        final titleFinder = find.byKey(
          ValueKey('province-download-card-title-$id'),
        );
        final sizeFinder = find.byKey(
          ValueKey('province-download-card-size-$id'),
        );
        void expectHeaderTextComplete(String phase) {
          expect(
            tester.renderObject<RenderParagraph>(titleFinder).didExceedMaxLines,
            isFalse,
            reason: '$id title clipped during $phase.',
          );
          expect(
            tester.renderObject<RenderParagraph>(sizeFinder).didExceedMaxLines,
            isFalse,
            reason: '$id size clipped during $phase.',
          );
        }

        final reveal = find.byKey(
          ValueKey('province-download-content-reveal-$id'),
        );
        final compactRect = tester.getRect(card);
        await tester.tap(
          find.byKey(ValueKey('province-download-indicator-$id')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expectHeaderTextComplete('mid-expansion');

        final midExpansionRect = tester.getRect(card);
        expect(midExpansionRect.height, greaterThan(compactRect.height));
        final expansionOpacity = tester.widget<Opacity>(reveal).opacity;
        expect(expansionOpacity, greaterThan(0));
        expect(expansionOpacity, lessThan(1));
        expect(find.text('Cartografía de suelos'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 180));
        expectHeaderTextComplete('late expansion');
        expect(tester.widget<Opacity>(reveal).opacity, lessThan(1));

        await tester.pumpAndSettle();
        expectHeaderTextComplete('expanded state');
        final expandedRect = tester.getRect(card);
        expect(expandedRect.height, greaterThan(midExpansionRect.height));
        expect(midExpansionRect.width, greaterThan(compactRect.width));
        expect(midExpansionRect.width, lessThan(expandedRect.width));
        expect(tester.widget<Opacity>(reveal).opacity, 1);

        await tester.tap(
          find.byKey(ValueKey('province-download-card-close-$id')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expectHeaderTextComplete('mid-collapse');

        final midCollapseRect = tester.getRect(card);
        final collapseOpacity = tester.widget<Opacity>(reveal).opacity;
        expect(midCollapseRect.height, lessThan(expandedRect.height));
        expect(midCollapseRect.height, greaterThan(compactRect.height));
        expect(midCollapseRect.width, lessThan(expandedRect.width));
        expect(midCollapseRect.width, greaterThan(compactRect.width));
        expect(collapseOpacity, greaterThan(0));
        expect(collapseOpacity, lessThan(1));
        expect(find.text('Cartografía de suelos'), findsOneWidget);

        await tester.pumpAndSettle();
        expectHeaderTextComplete('compact state');
        expect(tester.getRect(card).height, closeTo(compactRect.height, 1));
        expect(tester.widget<Opacity>(reveal).opacity, 0);
        expect(find.text('Cartografía de suelos'), findsNothing);
      }
    },
  );

  testWidgets('upward card collapse keeps its header attached to the card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 700),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    final indicator = find.byKey(
      const ValueKey('province-download-indicator-cordoba'),
    );
    final card = find.byKey(const ValueKey('province-download-card-cordoba'));
    final compactWidth = tester.getRect(card).width;
    await tester.tap(indicator);
    await tester.pumpAndSettle();
    final title = find.byKey(
      const ValueKey('province-download-card-title-cordoba'),
    );
    final size = find.byKey(
      const ValueKey('province-download-card-size-cordoba'),
    );
    final expandedTitleRect = tester.getRect(title);
    var previousCardRect = tester.getRect(card);
    final expandedTitleInset = expandedTitleRect.left - previousCardRect.left;
    final closeRect = tester.getRect(
      find.byKey(const ValueKey('province-download-card-close-cordoba')),
    );
    for (final key in [
      'province-download-description',
      'province-download-offline',
    ]) {
      expect(
        closeRect.overlaps(tester.getRect(find.byKey(ValueKey(key)))),
        isFalse,
        reason: '$key must not render beneath the close control.',
      );
    }

    await tester.tap(
      find.byKey(const ValueKey('province-download-card-close-cordoba')),
    );
    await tester.pump(Duration.zero);
    var previousTitleRect = expandedTitleRect;

    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 25));
      final titleRect = tester.getRect(title);
      final cardRect = tester.getRect(card);
      final titleRender = tester.renderObject<RenderParagraph>(title);
      expect(
        titleRender.didExceedMaxLines,
        isFalse,
        reason:
            'frame=$frame cardWidth=${cardRect.width} '
            'titleWidth=${titleRender.size.width} '
            'natural=${titleRender.getMaxIntrinsicWidth(double.infinity)}',
      );
      expect(
        tester.renderObject<RenderParagraph>(size).didExceedMaxLines,
        isFalse,
        reason: 'frame=$frame download size label should remain complete',
      );
      expect((titleRect.left - previousTitleRect.left).abs(), lessThan(16));
      expect((titleRect.top - previousTitleRect.top).abs(), lessThan(16));
      expect(titleRect.left - cardRect.left, closeTo(expandedTitleInset, 2));
      expect(cardRect.width, lessThan(previousCardRect.width));
      previousTitleRect = titleRect;
      previousCardRect = cardRect;
    }
    final atTransitionEnd = tester.getRect(title);
    final cardAtTransitionEnd = tester.getRect(card);
    expect((atTransitionEnd.left - previousTitleRect.left).abs(), lessThan(2));
    expect((atTransitionEnd.top - previousTitleRect.top).abs(), lessThan(2));
    expect(
      atTransitionEnd.left - cardAtTransitionEnd.left,
      closeTo(expandedTitleInset, 2),
    );
    expect(cardAtTransitionEnd.width, closeTo(compactWidth, 2));
    expect(
      tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('province-download-card-title-cordoba')),
      findsOneWidget,
    );
  });

  testWidgets(
    'edge-clamped card glides back to its compact geographic anchor',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      projectedAnchors = {
        'buenos_aires': const Offset(202, 620),
        'santa_fe': const Offset(252, 256),
        'cordoba': const Offset(107, 384),
      };
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
      );

      final card = find.byKey(const ValueKey('province-download-card-cordoba'));
      expect(tester.getRect(card).center.dx, closeTo(92, 1));
      await tester.tap(
        find.byKey(const ValueKey('province-download-indicator-cordoba')),
      );
      await tester.pumpAndSettle();
      final expandedRect = tester.getRect(card);
      expect(expandedRect.center.dx, greaterThan(92));

      await tester.tap(
        find.byKey(const ValueKey('province-download-card-close-cordoba')),
      );
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 150));
      final midCollapseRect = tester.getRect(card);
      expect(midCollapseRect.center.dx, lessThan(expandedRect.center.dx));
      expect(midCollapseRect.center.dx, greaterThan(92));

      await tester.pump(const Duration(milliseconds: 151));
      await tester.pumpAndSettle();
      expect(tester.getRect(card).center.dx, closeTo(92, 1));
    },
  );

  testWidgets('compact indicator fades before entering fixed top controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(190, 260),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );

    final card = find.byKey(const ValueKey('province-download-card-santa_fe'));
    final edgeOpacityFinder = find.ancestor(
      of: card,
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(edgeOpacityFinder.first).opacity, 1);
    projectedAnchors['santa_fe'] = const Offset(190, 180);
    cameraChanges.value++;
    await tester.pump();
    expect(
      tester.widget<Opacity>(edgeOpacityFinder.first).opacity,
      closeTo(0.18, 0.02),
    );
    expect(card, findsOneWidget);

    projectedAnchors['santa_fe'] = const Offset(190, 130);
    cameraChanges.value++;
    await tester.pump();
    expect(tester.widget<Opacity>(edgeOpacityFinder.first).opacity, 0);
    expect(card, findsOneWidget);
  });

  testWidgets('visible Santa Fe anchor clears the actual map controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(190, 180),
      'cordoba': const Offset(166, 384),
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildOverlay(
            makeItems(),
            mapFrameSynchronized: true,
            topOverlayClearance: 154,
          ),
        ),
      ),
    );

    final santaFeCard = find.byKey(
      const ValueKey('province-download-card-santa_fe'),
    );
    expect(santaFeCard, findsOneWidget);
    final opacity = find.ancestor(
      of: santaFeCard,
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(opacity.first).opacity, 1);
  });

  testWidgets('indicators remain available without the removed instruction', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
    );
    expect(
      find.text('Seleccioná una provincia para ver las opciones de descarga'),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
      findsOneWidget,
    );
  });

  testWidgets(
    'all three province cards expand in place without a bottom panel',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      projectedAnchors = {
        'buenos_aires': const Offset(202, 620),
        'santa_fe': const Offset(252, 256),
        'cordoba': const Offset(166, 384),
      };
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildOverlay(makeItems()))),
      );

      for (final id in ['santa_fe', 'cordoba', 'buenos_aires']) {
        final cardKey = ValueKey('province-download-card-$id');
        final initialBottom = tester.getBottomRight(find.byKey(cardKey)).dy;
        await tester.tap(
          find.byKey(ValueKey('province-download-indicator-$id')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(cardKey), findsOneWidget);
        final headerCenter = tester
            .getRect(find.byKey(ValueKey('province-download-header-$id')))
            .center;
        final expandedCardRect = tester.getRect(find.byKey(cardKey));
        expect(
          headerCenter.dx,
          inInclusiveRange(expandedCardRect.left, expandedCardRect.right),
        );
        expect(
          headerCenter.dy,
          inInclusiveRange(expandedCardRect.top, expandedCardRect.bottom),
        );
        expect(
          tester.getRect(find.byKey(cardKey)).left,
          greaterThanOrEqualTo(12),
        );
        expect(
          tester.getRect(find.byKey(cardKey)).right,
          lessThanOrEqualTo(348),
        );
        expect(
          tester.getSize(
            find.byKey(ValueKey('province-download-card-close-$id')),
          ),
          const Size(40, 40),
        );
        final cardRect = tester.getRect(find.byKey(cardKey));
        final closeRect = tester.getRect(
          find.byKey(ValueKey('province-download-card-close-$id')),
        );
        expect(closeRect.right, closeTo(cardRect.right - 12, 5));
        expect(closeRect.top, closeTo(cardRect.top + 6, 3));
        expect(
          find.descendant(
            of: find.byKey(ValueKey('province-download-header-$id')),
            matching: find.byIcon(Icons.keyboard_arrow_down),
          ),
          findsNothing,
        );
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey('province-download-shared-card')),
          findsNothing,
        );
        expect(find.byType(BottomSheet), findsNothing);
        final expandedRect = tester.getRect(find.byKey(cardKey));
        expect(expandedRect.height, greaterThan(44));
        if (id == 'buenos_aires') {
          expect((expandedRect.bottom - initialBottom).abs(), lessThan(32));
        }
        await tester.tap(
          find.byKey(ValueKey('province-download-card-close-$id')),
        );
        await tester.pump(const Duration(milliseconds: 181));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(cardKey)).height,
          inInclusiveRange(42, 46),
        );
      }
    },
  );

  testWidgets('reduced animations switch the same card without a tween', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    projectedAnchors = {
      'buenos_aires': const Offset(202, 620),
      'santa_fe': const Offset(252, 256),
      'cordoba': const Offset(166, 384),
    };

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(body: buildOverlay(makeItems())),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('province-download-indicator-santa_fe')),
    );
    await tester.pump();

    final card = find.byKey(const ValueKey('province-download-card-santa_fe'));
    expect(tester.getSize(card).height, greaterThan(44));
    expect(find.byIcon(AppIcons.close), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));
  });
}

class _FakeDelivery extends PmtilesDelivery {
  PmtilesDeliveryStatus _status = PmtilesDeliveryStatus.notInstalled;
  PmtilesDownloadBytes? _bytes;
  int downloadCalls = 0;

  @override
  PmtilesDeliveryStatus get status => _status;

  @override
  double? get downloadProgress => _bytes?.fraction;

  @override
  PmtilesDownloadBytes? get downloadBytes => _bytes;

  void reportProgress(int downloaded, int total) {
    _status = PmtilesDeliveryStatus.downloading;
    _bytes = PmtilesDownloadBytes.fromCounts(downloaded, total);
    notifyListeners();
  }

  void reportIndeterminate() {
    _status = PmtilesDeliveryStatus.downloading;
    _bytes = null;
    notifyListeners();
  }

  void reportAvailable() {
    _status = PmtilesDeliveryStatus.available;
    _bytes = null;
    notifyListeners();
  }

  void reportError() {
    _status = PmtilesDeliveryStatus.error;
    _bytes = null;
    notifyListeners();
  }

  @override
  Future<void> checkStatus() async {}

  @override
  Future<void> download() async {
    downloadCalls++;
    reportIndeterminate();
  }

  @override
  Future<void> uninstall() async {}

  @override
  File resolveWindowsArchiveFile() => File('fake.pmtiles');
}
