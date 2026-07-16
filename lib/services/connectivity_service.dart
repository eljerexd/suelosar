import 'dart:async';

enum ConnectivityStatus { online, offline }

/// Backend-neutral connectivity signal. A future platform adapter can update
/// this service without coupling the synchronization engine to a plugin.
class ConnectivityService {
  ConnectivityService({
    ConnectivityStatus initialStatus = ConnectivityStatus.offline,
  }) : _status = initialStatus;

  static final ConnectivityService instance = ConnectivityService();

  final StreamController<ConnectivityStatus> _controller =
      StreamController<ConnectivityStatus>.broadcast();
  ConnectivityStatus _status;

  ConnectivityStatus get status => _status;
  bool get isOnline => _status == ConnectivityStatus.online;
  Stream<ConnectivityStatus> get changes => _controller.stream;

  void update(ConnectivityStatus status) {
    if (_status == status) return;
    _status = status;
    _controller.add(status);
  }

  Future<void> dispose() => _controller.close();
}
