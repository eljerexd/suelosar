import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

abstract class DesktopWindowService extends ChangeNotifier {
  static final DesktopWindowService instance =
      WindowManagerDesktopWindowService();

  bool get isSupported;
  bool get isTransitioning;

  Future<void> initialize();
  Future<bool> isFullScreen();
  Future<void> enterFullScreen();
  Future<void> exitFullScreen();
  Future<void> toggleFullScreen();
  Future<void> closeWindow();
}

class WindowManagerDesktopWindowService extends DesktopWindowService
    with WindowListener {
  bool _isTransitioning = false;
  bool _listening = false;
  bool _ready = false;
  bool? _restoreMaximizedAfterFullScreen;
  Future<void>? _initialization;

  @override
  bool get isSupported =>
      !kIsWeb &&
      const {
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  @override
  bool get isTransitioning => _isTransitioning;

  @override
  Future<void> initialize() {
    if (!isSupported) return Future<void>.value();
    return _initialization ??= _initializeWindowManager();
  }

  Future<void> _initializeWindowManager() async {
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      _listening = true;
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  @override
  Future<bool> isFullScreen() async {
    await initialize();
    if (!isSupported || !_ready) return false;
    return windowManager.isFullScreen();
  }

  @override
  Future<void> enterFullScreen() => _setFullScreen(true);

  @override
  Future<void> exitFullScreen() => _setFullScreen(false);

  @override
  Future<void> toggleFullScreen() async {
    await initialize();
    if (!isSupported || !_ready || _isTransitioning) return;
    final nativeFullScreen = await windowManager.isFullScreen();
    await _setFullScreen(!nativeFullScreen);
  }

  @override
  Future<void> closeWindow() async {
    await initialize();
    if (!isSupported || !_ready) return;
    await windowManager.close();
  }

  Future<void> _setFullScreen(bool value) async {
    await initialize();
    if (!isSupported || !_ready || _isTransitioning) {
      return;
    }
    final nativeFullScreen = await windowManager.isFullScreen();
    if (nativeFullScreen == value) return;

    _isTransitioning = true;
    notifyListeners();
    try {
      if (value && defaultTargetPlatform == TargetPlatform.windows) {
        final wasMaximized = await windowManager.isMaximized();
        _restoreMaximizedAfterFullScreen = wasMaximized;
        if (wasMaximized) await windowManager.unmaximize();
      }
      await windowManager.setFullScreen(value);
      if (!value &&
          defaultTargetPlatform == TargetPlatform.windows &&
          (_restoreMaximizedAfterFullScreen ?? false)) {
        if (!await windowManager.isMaximized()) {
          await windowManager.maximize();
        }
      }
      if (!value) _restoreMaximizedAfterFullScreen = null;
    } catch (_) {
      if (value && (_restoreMaximizedAfterFullScreen ?? false)) {
        await windowManager.maximize();
      }
      _restoreMaximizedAfterFullScreen = null;
      rethrow;
    } finally {
      _isTransitioning = false;
      notifyListeners();
    }
  }

  @override
  void onWindowEnterFullScreen() => notifyListeners();

  @override
  void onWindowLeaveFullScreen() => notifyListeners();

  @override
  void onWindowMaximize() => notifyListeners();

  @override
  void onWindowUnmaximize() => notifyListeners();

  @override
  void onWindowRestore() => notifyListeners();

  @override
  void dispose() {
    if (_listening) windowManager.removeListener(this);
    super.dispose();
  }
}
