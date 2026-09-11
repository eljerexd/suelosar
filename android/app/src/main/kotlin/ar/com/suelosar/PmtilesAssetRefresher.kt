package ar.com.suelosar

import android.content.Context
import android.content.res.AssetManager
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
     * The AssetManager last handed to the engine, held for as long as the
     * engine uses it: the native side keeps only a reference to it, so letting
     * it go would leave that dangling.
     */
    private var assetManager: AssetManager? = null

    /** The split set [assetManager] was built from, so it is only rebuilt when
     * that set actually changes. Each instance holds open descriptors for
     * every APK it covers, so rebuilding on every refresh would bleed file
     * descriptors — a download runs up to six refreshes on its own. */
    private var assetPaths: List<String>? = null

    /** Where the current AssetManager came from, for the diagnostic log. */
    private var assetSource: String = "none"

    /** Held whenever the chosen AssetManager belongs to a package context:
     * the engine keeps only the AssetManager, so its owner has to outlive it. */
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

    /**
     * Deliberately keeps [flutterJNI].
     *
     * This arrives once per FlutterEngine, and engines can overlap: a
     * replacement engine hands over its own JNI through [setJNI] before the
     * outgoing one is destroyed, so clearing here would drop the live
     * reference and leave the refresher useless for the rest of the process.
     * Staleness is handled where it matters instead — [refresh] checks
     * `isAttached` before touching it.
     */
    override fun destroy() = Unit

    /**
     * Re-points the engine at an AssetManager that includes every module
     * installed so far — after a session reaches INSTALLED, and once at
     * startup for modules installed in an earlier session.
     *
     * Startup has to be driven from Dart (`refreshAssets` on
     * [PmtilesDeliveryBridge]) rather than from an Android lifecycle hook:
     * the engine hands itself a fresh AssetManager when it executes the Dart
     * entrypoint, so anything done before that is overwritten.
     *
     * Three steps, and all three are load-bearing:
     *
     *  1. `SplitCompat.install(context)` on the running application context.
     *     This is what refreshes the process's own `ApplicationInfo`, so
     *     `splitSourceDirs` below lists the modules Play has added since
     *     launch and not just the ones present at startup.
     *  2. An AssetManager built from that refreshed split list — see
     *     [buildAssetManager]. This replaced `createPackageContext`, which
     *     was the actual bug: asking the platform for a context on the app's
     *     own package returns the `LoadedApk` that `ActivityThread` cached at
     *     process start, so its AssetManager still covers only the original
     *     splits. Diagnostics proved it: with `split_buenosAiresPmtiles.apk`
     *     present in `splitSourceDirs` and the archive verifiably inside it,
     *     that AssetManager answered FileNotFoundException for Buenos Aires
     *     while resolving Santa Fe — installed before the process started —
     *     perfectly. It also returned in 0 ms, which is the giveaway that
     *     nothing was rebuilt.
     *  3. `updateJavaAssetManager`, which is what actually replaces the
     *     engine's native asset resolver. Everything above is only useful
     *     because of this call.
     *
     * Returns false rather than throwing, so the Dart side can retry: Play
     * signals INSTALLED as soon as the install is committed, which is not
     * always the same instant the assets become readable.
     */
    fun refresh(context: Context): Boolean {
        val jni = flutterJNI
        if (jni == null) {
            Log.w(TAG, "refresh skipped: no FlutterJNI")
            return false
        }
        if (!jni.isAttached) {
            Log.w(TAG, "refresh skipped: FlutterJNI is detached")
            return false
        }
        return runCatching {
            val startedAt = System.currentTimeMillis()
            val splitCompatInstalled = SplitCompat.install(context)
            val assets = resolveAssetManager(context)
            val assetsDir = FlutterInjector.instance().flutterLoader().findAppBundlePath()
            jni.updateJavaAssetManager(assets, assetsDir)
            Log.i(
                TAG,
                "refresh done in ${System.currentTimeMillis() - startedAt}ms" +
                    " (bundle=$assetsDir splitCompat.app=$splitCompatInstalled" +
                    " source=$assetSource paths=${assetPaths?.size ?: 0})",
            )
            true
        }.getOrElse { error ->
            Log.e(TAG, "asset manager refresh failed", error)
            false
        }
    }

    /**
     * The AssetManager to hand the engine: one covering every APK the process
     * currently has, rebuilt only when that set changes.
     *
     * Falls back to the application context's own AssetManager when a fresh
     * one cannot be built — [buildAssetManager] relies on non-SDK members, so
     * a future platform could refuse. That fallback is what SplitCompat has
     * already patched, so it is the next best thing rather than a broken one,
     * and it is also what covers the emulated splits of bundletool's
     * `--local-testing` harness, which are not real platform splits and so
     * never appear in `splitSourceDirs`.
     */
    private fun resolveAssetManager(context: Context): AssetManager {
        val info = context.applicationInfo
        val paths = buildList {
            info.sourceDir?.let(::add)
            info.splitSourceDirs?.let(::addAll)
        }
        val cached = assetManager
        if (cached != null && paths.isNotEmpty() && paths == assetPaths) {
            return cached
        }
        // Two delivery mechanisms, two different places a module can be, and
        // no single AssetManager covers both:
        //
        //  - Real Play splits land in `ApplicationInfo.splitSourceDirs`, and
        //    only a freshly built AssetManager over that list sees one that
        //    arrived after the process started. This is the production path.
        //  - The splits bundletool's `--local-testing` harness emulates are
        //    not platform splits at all: they never appear in
        //    `splitSourceDirs`, and what loads them is SplitCompat patching a
        //    newly created package context. This is the only path testable
        //    without Play ownership.
        //
        // So build both and pick by measurement rather than by assumption —
        // whichever actually resolves the province archives wins. Guessing is
        // what broke local testing: a manager built from `splitSourceDirs`
        // alone reported success while being blind to every emulated module.
        // Ordered so ties go to the long-standing behaviour: `maxByOrNull`
        // keeps the first of equal scores, so the package context — the path
        // that has always served the emulated splits — only loses when the
        // split-list manager can demonstrably see more provinces than it.
        val candidates = buildList {
            runCatching {
                val packaged = context.createPackageContext(context.packageName, 0)
                SplitCompat.install(packaged)
                packageContext = packaged
                add("packageContext" to packaged.assets)
            }
            if (paths.isNotEmpty()) {
                buildAssetManager(paths)?.let { add("splitSourceDirs" to it) }
            }
            add("appContext" to context.assets)
        }

        val best = candidates.maxByOrNull { provincesVisibleTo(it.second) }
            ?: ("appContext" to context.assets)
        assetManager = best.second
        assetPaths = paths
        assetSource = "${best.first}(${provincesVisibleTo(best.second)} provinces)"
        return best.second
    }

    /** How many province archives [assets] can actually resolve right now. */
    private fun provincesVisibleTo(assets: AssetManager): Int =
        PROVINCE_PROBE_ASSETS.count { canOpen(assets, it) }

    private fun canOpen(assets: AssetManager, path: String): Boolean =
        runCatching { assets.open(path).close() }.isSuccess

    /**
     * Builds an AssetManager over [paths] — the base APK plus every installed
     * split — using the platform's own `addAssetPath`.
     *
     * Both members are non-SDK, which is precisely why this is wrapped and
     * why [resolveAssetManager] has a fallback: `addAssetPath` has been
     * greylisted rather than blocked for many releases, but that is not a
     * guarantee. Returns null if the constructor is refused, the method is
     * gone, or no path was accepted, so a refusal degrades to the previous
     * behaviour instead of taking the app down.
     */
    private fun buildAssetManager(paths: List<String>): AssetManager? {
        return runCatching {
            val assets = AssetManager::class.java
                .getDeclaredConstructor()
                .apply { isAccessible = true }
                .newInstance()
            val addAssetPath = AssetManager::class.java
                .getMethod("addAssetPath", String::class.java)
            var accepted = 0
            for (path in paths) {
                val cookie = addAssetPath.invoke(assets, path) as? Int ?: 0
                if (cookie != 0) {
                    accepted++
                } else {
                    Log.w(TAG, "addAssetPath rejected $path")
                }
            }
            if (accepted == 0) {
                Log.w(TAG, "no asset path accepted; falling back")
                null
            } else {
                Log.i(TAG, "AssetManager built over $accepted/${paths.size} apks")
                assets
            }
        }.getOrElse { error ->
            Log.w(TAG, "could not build AssetManager from splitSourceDirs", error)
            null
        }
    }
}

/**
 * The two province archives, as the Android AssetManager addresses them.
 * Flutter packs `assets/maps/x.pmtiles` into the APK under `flutter_assets/`,
 * so these are the Dart paths with that prefix.
 */
private val PROVINCE_ASSETS = listOf(
    "flutter_assets/assets/maps/soil_polygons.pmtiles",
    "flutter_assets/assets/maps/santa_fe_soil_polygons.pmtiles",
)

/**
 * The tiny `.sha256` companions of [PROVINCE_ASSETS]. Probing those instead of
 * the archives keeps [PmtilesAssetRefresher] from streaming ~151 MB just to
 * answer "is this module visible?".
 */
private val PROVINCE_PROBE_ASSETS = PROVINCE_ASSETS.map { "$it.sha256" }
