import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/map_coverage.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';
import 'package:suelosar/screens/settings_screen.dart';

void main() {
  testWidgets('opens with the installed module state queried from delivery', (
    tester,
  ) async {
    final delivery = _FakeDelivery(PmtilesDeliveryStatus.notInstalled);
    delivery.onCheck = () async =>
        delivery.update(PmtilesDeliveryStatus.available);
    await _pumpManager(tester, [_coverage('buenos_aires', delivery)]);

    expect(delivery.checkCount, 1);
    await tester.pump();
    final card = find.byKey(const ValueKey('cartography-buenos_aires'));
    expect(
      find.descendant(of: card, matching: find.text('Disponible offline')),
      findsOneWidget,
    );
  });

  testWidgets('a module absent on cold start remains marked not downloaded', (
    tester,
  ) async {
    final delivery = _FakeDelivery(PmtilesDeliveryStatus.notInstalled);
    await _pumpManager(tester, [_coverage('santa_fe', delivery)]);
    await tester.pump();

    expect(delivery.checkCount, 1);
    final card = find.byKey(const ValueKey('cartography-santa_fe'));
    expect(
      find.descendant(of: card, matching: find.text('No descargada')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Descargar')),
      findsOneWidget,
    );
  });

  testWidgets('shows real progress only on the province reporting it', (
    tester,
  ) async {
    final buenosAires = _FakeDelivery(PmtilesDeliveryStatus.downloading)
      ..bytes = const PmtilesDownloadBytes(
        downloaded: 5 * 1024 * 1024,
        total: 50 * 1024 * 1024,
      );
    final santaFe = _FakeDelivery(PmtilesDeliveryStatus.downloading)
      ..bytes = const PmtilesDownloadBytes(
        downloaded: 20 * 1024 * 1024,
        total: 100 * 1024 * 1024,
      );
    final cordoba = _FakeDelivery(PmtilesDeliveryStatus.notInstalled);
    await _pumpManager(tester, [
      _coverage('buenos_aires', buenosAires),
      _coverage('santa_fe', santaFe),
      _coverage('cordoba', cordoba),
    ]);

    final buenosAiresCard = find.byKey(
      const ValueKey('cartography-buenos_aires'),
    );
    final santaFeCard = find.byKey(const ValueKey('cartography-santa_fe'));
    final cordobaCard = find.byKey(const ValueKey('cartography-cordoba'));
    expect(
      find.descendant(
        of: buenosAiresCard,
        matching: find.text('Descargando · 5.0 MB / 50.0 MB'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: buenosAiresCard, matching: find.text('10%')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: santaFeCard,
        matching: find.text('Descargando · 20.0 MB / 100.0 MB'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: santaFeCard, matching: find.text('20%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: cordobaCard, matching: find.text('No descargada')),
      findsOneWidget,
    );
  });

  testWidgets('completion updates the card to available and clears progress', (
    tester,
  ) async {
    final delivery = _FakeDelivery(PmtilesDeliveryStatus.downloading)
      ..bytes = const PmtilesDownloadBytes(downloaded: 2, total: 4);
    await _pumpManager(tester, [_coverage('cordoba', delivery)]);
    delivery.update(PmtilesDeliveryStatus.available);
    await tester.pump();

    final card = find.byKey(const ValueKey('cartography-cordoba'));
    expect(
      find.descendant(of: card, matching: find.text('Disponible offline')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Eliminar')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('Descargando ·')),
      findsNothing,
    );
  });

  testWidgets('reopening the manager refreshes delivery status again', (
    tester,
  ) async {
    final delivery = _FakeDelivery(PmtilesDeliveryStatus.notInstalled);
    final coverage = _coverage('buenos_aires', delivery);
    await _pumpManager(tester, [coverage]);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    delivery.onCheck = () async =>
        delivery.update(PmtilesDeliveryStatus.available);
    await _pumpManager(tester, [coverage]);
    await tester.pump();

    expect(delivery.checkCount, 2);
    final card = find.byKey(const ValueKey('cartography-buenos_aires'));
    expect(
      find.descendant(of: card, matching: find.text('Disponible offline')),
      findsOneWidget,
    );
  });

  testWidgets('pending status completion after disposal does not update UI', (
    tester,
  ) async {
    final pending = Completer<void>();
    final delivery = _FakeDelivery(PmtilesDeliveryStatus.notInstalled)
      ..onCheck = () => pending.future;
    await _pumpManager(tester, [_coverage('santa_fe', delivery)]);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    delivery.update(PmtilesDeliveryStatus.available);
    pending.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpManager(
  WidgetTester tester,
  List<MapCoverage> coverages,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProvinceCartographyManager.forTesting(coverages: coverages),
        ),
      ),
    ),
  );
}

MapCoverage _coverage(String id, _FakeDelivery delivery) {
  final registered = switch (id) {
    'buenos_aires' => MapCoverage.buenosAires,
    'santa_fe' => MapCoverage.santaFe,
    'cordoba' => MapCoverage.cordoba,
    _ => throw ArgumentError.value(id, 'id'),
  };
  return MapCoverage(
    config: registered.config,
    bounds: registered.bounds,
    onDemandDelivery: delivery,
  );
}

class _FakeDelivery extends PmtilesDelivery {
  _FakeDelivery(this._status);

  PmtilesDeliveryStatus _status;
  PmtilesDownloadBytes? bytes;
  int checkCount = 0;
  Future<void> Function()? onCheck;

  @override
  PmtilesDeliveryStatus get status => _status;

  @override
  PmtilesDownloadBytes? get downloadBytes => bytes;

  @override
  Future<void> checkStatus() async {
    checkCount++;
    await onCheck?.call();
  }

  @override
  Future<void> download() async => update(PmtilesDeliveryStatus.available);

  @override
  Future<void> uninstall() async => update(PmtilesDeliveryStatus.notInstalled);

  void update(PmtilesDeliveryStatus status, {PmtilesDownloadBytes? progress}) {
    _status = status;
    bytes = progress;
    notifyListeners();
  }

  @override
  File resolveWindowsArchiveFile() => File('unused');
}
