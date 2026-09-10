package ar.com.suelosar

import android.content.Context
import com.baseflow.geolocator.GeolocatorPlugin
import com.google.android.play.core.splitcompat.SplitCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var pmtilesDeliveryBridge: PmtilesDeliveryBridge? = null

    /**
     * Makes any already-installed feature module visible to this activity's
     * own resources and assets. SuelosArApplication covers the application
     * context; this covers the activity context, which is what Android's own
     * Play Feature Delivery guide asks for.
     */
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
