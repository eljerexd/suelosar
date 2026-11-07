import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/engine/serial_async_queue.dart';

void main() {
  test('serializes concurrent source installation requests', () async {
    final queue = SerialAsyncQueue();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var activeTasks = 0;
    var maximumActiveTasks = 0;
    final order = <int>[];

    Future<void> install(int id, {Future<void>? waitFor}) async {
      activeTasks++;
      maximumActiveTasks = activeTasks > maximumActiveTasks
          ? activeTasks
          : maximumActiveTasks;
      order.add(id);
      if (id == 1) firstStarted.complete();
      if (waitFor != null) await waitFor;
      activeTasks--;
    }

    final first = queue.run(() => install(1, waitFor: releaseFirst.future));
    await firstStarted.future;
    final second = queue.run(() => install(2));

    expect(order, [1]);
    releaseFirst.complete();
    await Future.wait([first, second]);

    expect(order, [1, 2]);
    expect(maximumActiveTasks, 1);
  });

  test('a failed task does not block a later installation', () async {
    final queue = SerialAsyncQueue();
    final failure = queue.run<void>(() async => throw StateError('failed'));
    final next = queue.run(() async => 'installed');

    await expectLater(failure, throwsStateError);
    expect(await next, 'installed');
  });

  test(
    'latest-value pump coalesces rapid updates without stale overwrite',
    () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final applied = <int>[];
      final pump = LatestValueAsyncPump<int>((value) async {
        applied.add(value);
        if (value == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }
      });

      final first = pump.submit(1);
      await firstStarted.future;
      final superseded = pump.submit(2);
      final latest = pump.submit(3);
      releaseFirst.complete();
      await Future.wait([first, superseded, latest]);

      expect(applied, [1, 3]);
    },
  );

  test(
    'latest-value pump applies a final update arriving at completion',
    () async {
      final applied = <int>[];
      final pump = LatestValueAsyncPump<int>((value) async {
        applied.add(value);
      });

      await pump.submit(4);
      await pump.submit(5);

      expect(applied, [4, 5]);
    },
  );
}
