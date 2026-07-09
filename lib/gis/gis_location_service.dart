import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:latlong2/latlong.dart';

/// Location access used by GIS screens without exposing the GPS plugin.
abstract interface class GisLocationService {
  Future<GisLocation> getCurrentLocation();
}

/// Optional continuous updates supported by location services that can watch.
abstract interface class GisLocationUpdates {
  Stream<GisLocation> watchLocation();
}

class GisLocation {
  const GisLocation({required this.point, this.accuracyMeters});

  final LatLng point;
  final double? accuracyMeters;
}

class GisLocationException implements Exception {
  const GisLocationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DeviceGisLocationService
    implements GisLocationService, GisLocationUpdates {
  const DeviceGisLocationService();

  @override
  Future<GisLocation> getCurrentLocation() async {
    final serviceEnabled =
        await geolocator.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const GisLocationException(
        'Activá la ubicación del dispositivo para usar esta función.',
      );
    }

    final permission = await _requestPermissionIfNeeded();
    if (permission == geolocator.LocationPermission.denied ||
        permission == geolocator.LocationPermission.deniedForever ||
        permission == geolocator.LocationPermission.unableToDetermine) {
      throw const GisLocationException('Permiso de ubicación denegado.');
    }

    final position = await geolocator.Geolocator.getCurrentPosition(
      locationSettings: const geolocator.LocationSettings(
        accuracy: geolocator.LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );

    final location = _locationFromPosition(position);
    if (location == null) {
      throw const GisLocationException('La ubicaciÃ³n recibida no es vÃ¡lida.');
    }
    return location;
  }

  @override
  Stream<GisLocation> watchLocation() {
    return geolocator.Geolocator.getPositionStream(
      locationSettings: const geolocator.LocationSettings(
        accuracy: geolocator.LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).map(_locationFromPosition).where((location) => location != null).cast();
  }

  Future<geolocator.LocationPermission> _requestPermissionIfNeeded() async {
    var permission = await geolocator.Geolocator.checkPermission();
    if (permission == geolocator.LocationPermission.denied) {
      permission = await geolocator.Geolocator.requestPermission();
    }
    return permission;
  }

  GisLocation? _locationFromPosition(geolocator.Position position) {
    final latitude = position.latitude;
    final longitude = position.longitude;
    if (!_isFiniteCoordinateValues(latitude, longitude)) {
      return null;
    }
    return GisLocation(
      point: LatLng(latitude, longitude),
      accuracyMeters: position.accuracy,
    );
  }

  bool _isFiniteCoordinateValues(double latitude, double longitude) {
    return _isFiniteNumber(latitude) && _isFiniteNumber(longitude);
  }

  bool _isFiniteNumber(double value) {
    return value.isFinite && !value.isNaN;
  }
}
