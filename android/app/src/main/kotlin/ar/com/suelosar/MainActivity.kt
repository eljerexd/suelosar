package ar.com.suelosar

import android.content.Context
import com.baseflow.geolocator.GeolocatorPlugin
import com.google.android.play.core.splitcompat.SplitCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var pmtilesDeliveryBridge: PmtilesDeliveryBridge? = null

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        SplitCompat.installActivity(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (BuildConfig.DISABLE_GEOLOCATOR_DIAGNOSTIC) {
            flutterEngine.plugins.remove(GeolocatorPlugin::class.java)
        }

        pmtilesDeliveryBridge = PmtilesDeliveryBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also { it.activity = this }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pmtilesDeliveryBridge?.dispose()
        pmtilesDeliveryBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
