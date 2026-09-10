package ar.com.suelosar

import android.content.Context
import android.util.Log
import com.google.android.play.core.splitcompat.SplitCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.embedding.engine.deferredcomponents.DeferredComponentManager
import io.flutter.embedding.engine.systemchannels.DeferredComponentChannel

/**
 * Makes the assets of a feature module installed at runtime visible to Dart's
 * `rootBundle`.
 *
 * Installing a split is only half the job. The Flutter engine resolves assets
 * through a native handle taken from the AssetManager it was handed when the
 * process started, so a module that arrives afterwards is invisible to
 * `rootBundle` until that handle is replaced — the province archive downloads
 * and installs perfectly, and every `rootBundle.load` for it still throws.
 * Flutter's own PlayStoreDeferredComponentManager does the replacing in
 * `loadAssets`; this app does not use that manager (see [SuelosArApplication]),
 * so it has to do the same thing itself.
 *
 * The only way to reach the engine's [FlutterJNI] from application code is the
 * [DeferredComponentManager] hook: FlutterEngine's constructor passes its JNI
 * to whatever manager [FlutterInjector] holds. So this implements the
 * interface purely to receive that reference — every deferred-component method
 * is a deliberate no-op, because nothing in this app calls Dart's
 * `DeferredComponent` API. Play Feature Delivery is driven end to end by
 * [PmtilesDeliveryBridge] instead.
 */
class PmtilesAssetRefresher private constructor() : DeferredComponentManager {

    companion object {
        const val TAG = "SuelosArPad"

        @Volatile
        var instance: PmtilesAssetRefresher? = null
            private set

        /**
         * Must run before anything touches [FlutterInjector] — in practice,
         * from `Application.onCreate`, well before the first FlutterActivity.
         */
        fun register() {
            if (instance != null) return
            val refresher = PmtilesAssetRefresher()
            runCatching {
                FlutterInjector.setInstance(
                    FlutterInjector.Builder()
                        .setDeferredComponentManager(refresher)
                        .build(),
                )
            }.onFailure { error ->
                // Only happens if the injector was already read, which would
                // mean this ran too late. Nothing to recover: the app still
                // works, downloaded provinces just will not resolve until the
                // next launch, when SplitCompat covers them at startup.
                Log.w(TAG, "FlutterInjector already initialised", error)
                return
            }
            instance = refresher
            Log.i(TAG, "asset refresher registered")
        }
    }

    private var flutterJNI: FlutterJNI? = null

    /**
     * Held for as long as the engine uses its AssetManager: the native side
     * keeps only a reference to the AssetManager, so letting its context go
     * would leave that dangling.
     */
    private var packageContext: Context? = null

    override fun setJNI(jni: FlutterJNI) {
        flutterJNI = jni
    }

    override fun setDeferredComponentChannel(channel: DeferredComponentChannel) = Unit

    override fun installDeferredComponent(loadingUnitId: Int, componentName: String) = Unit

    override fun getDeferredComponentInstallState(
        loadingUnitId: Int,
        componentName: String,
    ): String = "unknown"

    override fun loadAssets(loadingUnitId: Int, componentName: String) = Unit

    override fun loadDartLibrary(loadingUnitId: Int, componentName: String) = Unit

    override fun uninstallDeferredComponent(loadingUnitId: Int, componentName: String) = false

    override fun destroy() {
        flutterJNI = null
    }

    /**
     * Re-points the engine at an AssetManager that includes every module
     * installed so far — once a session reaches INSTALLED, and once at
     * startup for modules installed in an earlier session.
     *
     * Startup has to be driven from Dart (`refreshAssets` on
     * [PmtilesDeliveryBridge]) rather than from an Android lifecycle hook:
     * the engine hands itself a fresh AssetManager when it executes the Dart
     * entrypoint, so anything done before that is overwritten.
     *
     * The fresh package context picks up splits the platform installed;
     * [SplitCompat] adds the ones emulated by bundletool's `--local-testing`
     * harness, which the platform knows nothing about. Both paths matter —
     * the first is production, the second is how this gets tested.
     */
    fun refresh(context: Context): Boolean {
        val jni = flutterJNI
        if (jni == null) {
            Log.w(TAG, "refresh skipped: no FlutterJNI")
            return false
        }
        return runCatching {
            val packaged = context.createPackageContext(context.packageName, 0)
            SplitCompat.install(packaged)
            val assetsDir = FlutterInjector.instance().flutterLoader().findAppBundlePath()
            jni.updateJavaAssetManager(packaged.assets, assetsDir)
            packageContext = packaged
            Log.i(TAG, "asset manager refreshed (bundle=$assetsDir)")
            true
        }.getOrElse { error ->
            Log.e(TAG, "asset manager refresh failed", error)
            false
        }
    }
}
