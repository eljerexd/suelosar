package ar.com.suelosar

import com.baseflow.geolocator.GeolocatorPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (BuildConfig.DISABLE_GEOLOCATOR_DIAGNOSTIC) {
            flutterEngine.plugins.remove(GeolocatorPlugin::class.java)
        }
    }
}
