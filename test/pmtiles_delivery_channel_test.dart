import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/pmtiles_delivery_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const events = EventChannel('ar.com.suelosar/pmtiles_delivery/events');
  const methods = MethodChannel('ar.com.suelosar/pmtiles_delivery');

  test(
    'serializes province sessions and keeps progress with each module',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final started = <(String, int)>[];
      final startWaiters = <Completer<(String, int)>>[];
      late MockStreamHandlerEventSink sink;
      var listenCount = 0;
      var activeListeners = 0;
      var maximumActiveListeners = 0;
      var nextSessionId = 100;
      final latestSession = <String, int>{};

      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, eventSink) {
            listenCount++;
            activeListeners++;
            if (activeListeners > maximumActiveListeners) {
              maximumActiveListeners = activeListeners;
            }
            sink = eventSink;
          },
          onCancel: (_) => activeListeners--,
        ),
      );
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'install');
        final module =
            (call.arguments as Map<Object?, Object?>)['module']! as String;
        final sessionId = nextSessionId++;
        latestSession[module] = sessionId;
        final entry = (module, sessionId);
        started.add(entry);
        if (startWaiters.isNotEmpty) {
          startWaiters.removeAt(0).complete(entry);
        }
        // Play can report state before the method-channel session ID returns.
        sink.success(
          _update(
            sessionId: sessionId,
            module: module,
            status: 'downloading',
            downloaded: 2,
            total: 10,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return sessionId;
      });

      Future<(String, int)> nextStarted(int index) {
        if (started.length > index) return Future.value(started[index]);
        final waiter = Completer<(String, int)>();
        startWaiters.add(waiter);
        return waiter.future;
      }

      const pairs = [
        ('buenosAiresPmtiles', 'santaFePmtiles'),
        ('buenosAiresPmtiles', 'cordobaPmtiles'),
        ('santaFePmtiles', 'cordobaPmtiles'),
      ];
      var expectedStarted = 0;
      for (final (firstModule, secondModule) in pairs) {
        final firstUpdates = <PmtilesInstallUpdate>[];
        final secondUpdates = <PmtilesInstallUpdate>[];
        final first = PmtilesDeliveryChannel.installAndWait(
          module: firstModule,
          timeout: const Duration(seconds: 2),
          onUpdate: firstUpdates.add,
        );
        final duplicateFirst = PmtilesDeliveryChannel.installAndWait(
          module: firstModule,
          timeout: const Duration(seconds: 2),
          onUpdate: (_) {},
        );
        expect(identical(first, duplicateFirst), isTrue);
        final second = PmtilesDeliveryChannel.installAndWait(
          module: secondModule,
          timeout: const Duration(seconds: 2),
          onUpdate: secondUpdates.add,
        );

        final firstStart = await nextStarted(expectedStarted++);
        expect(firstStart.$1, firstModule);
        expect(started.length, expectedStarted);
        expect(listenCount, expectedStarted);
        expect(activeListeners, 1);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final firstSession = firstStart.$2;
        expect(firstUpdates.last.sessionId, firstSession);
        expect(firstUpdates.last.progress, closeTo(0.2, 1e-12));

        // A stale terminal event for the same module cannot finish this run.
        sink.success(
          _update(
            sessionId: latestSession[firstModule]! - 50,
            module: firstModule,
            status: 'installed',
            downloaded: 10,
            total: 10,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(firstUpdates.last.sessionId, firstSession);

        sink.success(
          _update(
            sessionId: firstSession,
            module: firstModule,
            status: 'downloading',
            downloaded: 8,
            total: 10,
          ),
        );
        sink.success(
          _update(
            sessionId: firstSession,
            module: firstModule,
            status: 'installed',
            downloaded: 10,
            total: 10,
          ),
        );
        await Future.wait([first, duplicateFirst]);
        expect(firstUpdates.last.progress, 1);

        final secondStart = await nextStarted(expectedStarted++);
        expect(secondStart.$1, secondModule);
        expect(activeListeners, 1);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final secondSession = secondStart.$2;
        expect(secondUpdates.last.sessionId, secondSession);
        expect(secondUpdates.last.progress, closeTo(0.2, 1e-12));
        expect(
          firstUpdates.every((event) => event.modules.contains(firstModule)),
          isTrue,
        );

        sink.success(
          _update(
            sessionId: secondSession,
            module: secondModule,
            status: 'downloading',
            downloaded: 7,
            total: 10,
          ),
        );
        sink.success(
          _update(
            sessionId: secondSession,
            module: secondModule,
            status: 'installed',
            downloaded: 10,
            total: 10,
          ),
        );
        await second;
        expect(secondUpdates.last.progress, 1);
        expect(maximumActiveListeners, 1);
      }
    },
  );

  test(
    'a failed session exits promptly and a later explicit retry can finish',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final listenerReady = Completer<void>();
      late MockStreamHandlerEventSink sink;
      var nextSessionId = 500;

      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, eventSink) {
            sink = eventSink;
            if (!listenerReady.isCompleted) listenerReady.complete();
          },
        ),
      );
      messenger.setMockMethodCallHandler(
        methods,
        (call) async => nextSessionId++,
      );

      Future<void> request() => PmtilesDeliveryChannel.installAndWait(
        module: 'santaFePmtiles',
        timeout: const Duration(seconds: 2),
        onUpdate: (_) {},
      );

      final failed = request();
      await listenerReady.future;
      await Future<void>.delayed(Duration.zero);
      sink.success(
        _update(
          sessionId: 500,
          module: 'santaFePmtiles',
          status: 'failed',
          errorCode: -6,
        ),
      );
      await expectLater(failed, throwsA(isA<PmtilesInstallException>()));

      await Future<void>.delayed(Duration.zero);
      final retried = request();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sink.success(
        _update(
          sessionId: 501,
          module: 'santaFePmtiles',
          status: 'downloading',
          downloaded: 4,
          total: 10,
        ),
      );
      sink.success(
        _update(
          sessionId: 501,
          module: 'santaFePmtiles',
          status: 'installed',
          downloaded: 10,
          total: 10,
        ),
      );
      await retried;
    },
  );

  test(
    'a Play service death with session -1 fails instead of waiting for timeout',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final listenerReady = Completer<void>();
      late MockStreamHandlerEventSink sink;

      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, eventSink) {
            sink = eventSink;
            if (!listenerReady.isCompleted) listenerReady.complete();
          },
        ),
      );
      messenger.setMockMethodCallHandler(methods, (call) async => 900);

      final elapsed = Stopwatch()..start();
      final request = PmtilesDeliveryChannel.installAndWait(
        module: 'cordobaPmtiles',
        timeout: const Duration(seconds: 30),
        onUpdate: (_) {},
      );
      await listenerReady.future;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sink.success(
        _update(
          sessionId: -1,
          module: 'cordobaPmtiles',
          status: 'failed',
          errorCode: -1,
        ),
      );

      await expectLater(request, throwsA(isA<PmtilesInstallException>()));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );
}

Map<String, Object?> _update({
  required int sessionId,
  required String module,
  required String status,
  int errorCode = 0,
  int downloaded = 0,
  int total = 0,
}) => {
  'sessionId': sessionId,
  'status': status,
  'errorCode': errorCode,
  'bytesDownloaded': downloaded,
  'totalBytesToDownload': total,
  'modules': [module],
};
