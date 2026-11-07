import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/constants/app_icons.dart';
import 'package:suelosar/widgets/update_feedback_notification.dart';

void main() {
  testWidgets('success feedback uses the SuelosAR success surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UpdateFeedbackNotification(
            type: UpdateFeedbackType.success,
            reduceAnimations: true,
          ),
        ),
      ),
    );

    expect(find.text('Ya tenés la última versión.'), findsOneWidget);
    expect(find.byIcon(AppIcons.success), findsOneWidget);
    final surface = tester.widget<Material>(
      find.byKey(const ValueKey('update-feedback-surface')),
    );
    expect(surface.color, const Color(0xFFF1F5EC));
    expect(
      find.byKey(const ValueKey('update-feedback-transition')),
      findsNothing,
    );
  });

  testWidgets('error feedback uses the offline message and icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UpdateFeedbackNotification(
            type: UpdateFeedbackType.error,
            reduceAnimations: true,
          ),
        ),
      ),
    );

    expect(
      find.text('No se pudo comprobar si hay actualizaciones.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(
      tester
          .widget<Material>(
            find.byKey(const ValueKey('update-feedback-surface')),
          )
          .color,
      const Color(0xFFF4F2EC),
    );
  });

  testWidgets('checking feedback shows a discreet progress indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UpdateFeedbackNotification(
            type: UpdateFeedbackType.checking,
            reduceAnimations: false,
          ),
        ),
      ),
    );

    expect(find.text('Buscando actualizaciones...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-feedback-progress')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('update-feedback-transition')),
      findsOneWidget,
    );
  });

  testWidgets('presenter automatically dismisses transient feedback', (
    tester,
  ) async {
    final presenter = UpdateFeedbackPresenter();
    addTearDown(presenter.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await presenter.show(context, UpdateFeedbackType.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Ya tenés la última versión.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Ya tenés la última versión.'), findsNothing);
  });

  testWidgets('a new operation replaces the current notice without stacking', (
    tester,
  ) async {
    final presenter = UpdateFeedbackPresenter();
    addTearDown(presenter.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await presenter.show(context, UpdateFeedbackType.checking);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Buscando actualizaciones...'), findsOneWidget);
    final duplicate = presenter.show(context, UpdateFeedbackType.checking);
    await tester.pump(const Duration(milliseconds: 20));
    await duplicate;
    expect(
      find.byKey(const ValueKey('update-feedback-surface')),
      findsOneWidget,
    );

    final replacement = presenter.show(context, UpdateFeedbackType.success);
    await tester.pump(const Duration(milliseconds: 300));
    await replacement;
    await tester.pumpAndSettle();
    expect(find.text('Buscando actualizaciones...'), findsNothing);
    expect(find.text('Ya tenés la última versión.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-feedback-surface')),
      findsOneWidget,
    );
  });

  testWidgets('floating notice fits narrow and wide Windows windows', (
    tester,
  ) async {
    final presenter = UpdateFeedbackPresenter();
    addTearDown(presenter.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    for (final size in const [
      Size(320, 700),
      Size(600, 800),
      Size(1400, 900),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pump();
      await presenter.show(context, UpdateFeedbackType.error);
      await tester.pump(const Duration(milliseconds: 300));
      final surface = tester.getRect(
        find.byKey(const ValueKey('update-feedback-surface')),
      );
      expect(surface.left, greaterThanOrEqualTo(0));
      expect(surface.right, lessThanOrEqualTo(size.width));
      expect(tester.takeException(), isNull);
      await presenter.dismiss();
      await tester.pump(const Duration(milliseconds: 300));
    }
    tester.view.reset();
  });
}
