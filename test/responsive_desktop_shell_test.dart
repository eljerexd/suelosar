import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/widgets/responsive_desktop_shell.dart';

void main() {
  test('responsive layout uses the documented breakpoints', () {
    expect(SuelosArResponsiveLayout.fromWidth(699).isPhone, isTrue);
    expect(SuelosArResponsiveLayout.fromWidth(700).isTablet, isTrue);
    expect(SuelosArResponsiveLayout.fromWidth(1200).isTablet, isTrue);
    expect(SuelosArResponsiveLayout.fromWidth(1201).isDesktop, isTrue);
    final narrowDesktop = SuelosArResponsiveLayout.fromWidth(
      640,
      desktopPlatform: true,
    );
    expect(narrowDesktop.isDesktop, isTrue);
    expect(narrowDesktop.desktopDensity, SuelosArDesktopDensity.compact);
  });

  testWidgets('desktop scaffold leaves the phone child untouched', (
    tester,
  ) async {
    _setViewport(tester, 390);
    await tester.pumpWidget(
      const MaterialApp(
        home: SuelosArDesktopPageScaffold(
          sidePanel: SuelosArFloatingSidePanel(child: Text('Panel lateral')),
          informationPanel: SuelosArFloatingInformationPanel(
            child: Text('Información'),
          ),
          child: SizedBox(key: ValueKey('page-child')),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('page-child')), findsOneWidget);
    expect(find.text('Panel lateral'), findsNothing);
    expect(find.text('Información'), findsNothing);
  });

  testWidgets('desktop scaffold displays floating panels on desktop', (
    tester,
  ) async {
    _setViewport(tester, 1280);
    await tester.pumpWidget(
      const MaterialApp(
        home: SuelosArDesktopPageScaffold(
          sidePanel: SuelosArFloatingSidePanel(child: Text('Panel lateral')),
          informationPanel: SuelosArFloatingInformationPanel(
            child: Text('Información'),
          ),
          child: SizedBox(key: ValueKey('page-child')),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('page-child')), findsOneWidget);
    expect(find.text('Panel lateral'), findsOneWidget);
    expect(find.text('Información'), findsOneWidget);
  });
}

void _setViewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 700);
  addTearDown(tester.view.reset);
}
