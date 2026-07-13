import 'package:flutter/material.dart';

class GisMapOcclusionObserver extends NavigatorObserver {
  GisMapOcclusionObserver._();

  static final GisMapOcclusionObserver instance = GisMapOcclusionObserver._();

  final List<Route<dynamic>> _routes = <Route<dynamic>>[];
  final Map<Route<dynamic>, ValueChanged<double>> _listeners =
      <Route<dynamic>, ValueChanged<double>>{};

  void register(Route<dynamic> route, ValueChanged<double> listener) {
    _routes.removeWhere((candidate) => candidate.navigator == null);
    _listeners[route] = listener;
    _notifyRoute(route, listener);
  }

  void unregister(Route<dynamic> route) {
    _listeners.remove(route);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _routes.add(route);
    _notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (oldRoute != null) _routes.remove(oldRoute);
    if (newRoute != null) {
      if (index >= 0 && index <= _routes.length) {
        _routes.insert(index, newRoute);
      } else {
        _routes.add(newRoute);
      }
    }
    _notifyListeners();
  }

  void _notifyListeners() {
    for (final entry in List.of(_listeners.entries)) {
      _notifyRoute(entry.key, entry.value);
    }
  }

  void _notifyRoute(
    Route<dynamic> observedRoute,
    ValueChanged<double> listener,
  ) {
    final routeIndex = _routes.indexOf(observedRoute);
    if (routeIndex == -1) {
      listener(0);
      return;
    }
    final navigator = observedRoute.navigator;
    final isObscured = _routes
        .skip(routeIndex + 1)
        .any(
          (route) =>
              identical(route.navigator, navigator) &&
              route is TransitionRoute<dynamic> &&
              route.opaque,
        );
    listener(isObscured ? 1 : 0);
  }
}
