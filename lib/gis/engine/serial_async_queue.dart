import 'dart:async';

class SerialAsyncQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }
}

/// Serializes asynchronous rendering updates while discarding snapshots that
/// have already been superseded by a newer value.
class LatestValueAsyncPump<T> {
  LatestValueAsyncPump(this._apply);

  final Future<void> Function(T value) _apply;
  T? _latest;
  bool _hasLatest = false;
  Future<void>? _drain;

  Future<void> submit(T value) {
    _latest = value;
    _hasLatest = true;
    return _drain ??= _run();
  }

  Future<void> _run() async {
    try {
      while (_hasLatest) {
        final value = _latest as T;
        _hasLatest = false;
        await _apply(value);
      }
    } finally {
      _drain = null;
      if (_hasLatest) {
        unawaited(submit(_latest as T));
      }
    }
  }
}
