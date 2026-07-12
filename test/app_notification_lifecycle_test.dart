import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/widgets/app_notification.dart';

void main() {
  testWidgets('notification completes when its overlay is disposed', (
    tester,
  ) async {
    addTearDown(AppNotification.dismiss);
    late BuildContext notificationContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            notificationContext = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );

    final completion = AppNotification.show(
      notificationContext,
      message: 'Aviso temporal',
    );
    var completed = false;
    completion.then((_) => completed = true);
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(completed, isTrue);
  });
}
