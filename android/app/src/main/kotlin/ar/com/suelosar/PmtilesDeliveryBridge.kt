package ar.com.suelosar

import android.app.Activity
import android.content.Context
import android.util.Log
import com.google.android.play.core.splitinstall.SplitInstallException
import com.google.android.play.core.splitinstall.SplitInstallManager
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Drives Play Feature Delivery for the provincial PMTiles modules
 * (`buenosAiresPmtiles`, `santaFePmtiles`) directly, on the modern
 * com.google.android.play:feature-delivery API.
 *
 * This exists in place of Flutter's own `DeferredComponent` channel, which
 * routes to a PlayStoreDeferredComponentManager compiled against the legacy
 * com.google.android.play:core — the artifact Google Play rejects for
 * targetSdk 34+. The surface here is deliberately narrow: install, status,
 * uninstall, cancel, plus a stream of session updates. It knows nothing about
 * provinces or maps; the Dart side passes module names through.
 */
class PmtilesDeliveryBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "ar.com.suelosar/pmtiles_delivery"
        const val EVENT_CHANNEL = "ar.com.suelosar/pmtiles_delivery/events"

        /** Arbitrary; the result is never read, see [requestUserConfirmation]. */
        private const val CONFIRMATION_REQUEST_CODE = 0x5541

        private const val TAG = PmtilesAssetRefresher.TAG
    }

    private val manager: SplitInstallManager =
        SplitInstallManagerFactory.create(context)

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
        setMethodCallHandler(this@PmtilesDeliveryBridge)
    }
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
        setStreamHandler(this@PmtilesDeliveryBridge)
    }

    private var events: EventChannel.EventSink? = null

    /**
     * Set by [MainActivity] while it is attached. Only needed for
     * REQUIRES_USER_CONFIRMATION, which Play raises for large downloads over a
     * metered connection — Buenos Aires is ~151 MB, so this is a routine path,
     * not an edge case.
     */
    var activity: Activity? = null

    private val listener = SplitInstallStateUpdatedListener { state ->
        Log.i(
            TAG,
            "session ${state.sessionId()} ${statusName(state.status())}" +
                " err=${state.errorCode()} modules=${state.moduleNames()}" +
                " ${state.bytesDownloaded()}/${state.totalBytesToDownload()}",
        )
        // Ordered deliberately: Dart reads INSTALLED as "the assets are
        // readable now", so the engine has to be able to see them before that
        // update goes out.
        if (state.status() == SplitInstallSessionStatus.INSTALLED) {
            PmtilesAssetRefresher.instance?.refresh(context)
        }
        emit(state)
        if (state.status() == SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION) {
            requestUserConfirmation(state)
        }
    }

    init {
        manager.registerListener(listener)
        Log.i(
            TAG,
            "bridge ready (manager=${manager.javaClass.name}," +
                " installed=${manager.installedModules})",
        )
    }

    fun dispose() {
        manager.unregisterListener(listener)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        events = null
        activity = null
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "isInstalled" -> {
                val module = call.argument<String>("module")
                if (module == null) {
                    result.error("bad_args", "module is required", null)
                } else {
                    result.success(manager.installedModules.contains(module))
                }
            }

            "refreshAssets" -> {
                // Dart asks for this once per process, before its first probe
                // of a province archive. It has to be Dart that asks: the
                // engine re-installs its own AssetManager when it executes the
                // entrypoint, so anything done from `configureFlutterEngine`
                // is simply overwritten a moment later.
                result.success(PmtilesAssetRefresher.instance?.refresh(context) ?: false)
            }

            "install" -> {
                val module = call.argument<String>("module")
                if (module == null) {
                    result.error("bad_args", "module is required", null)
                    return
                }
                if (manager.installedModules.contains(module)) {
                    // Already there: report success immediately rather than
                    // opening a session Play would resolve as a no-op. Still
                    // refresh, because "already installed" covers the case
                    // where Play added it while this process was running.
                    PmtilesAssetRefresher.instance?.refresh(context)
                    Log.i(TAG, "install $module: already installed")
                    result.success(0)
                    return
                }
                val request = SplitInstallRequest.newBuilder()
                    .addModule(module)
                    .build()
                manager.startInstall(request)
                    .addOnSuccessListener { sessionId ->
                        Log.i(TAG, "install $module: session $sessionId")
                        result.success(sessionId)
                    }
                    .addOnFailureListener { error ->
                        // Surfaces Play's own error code when it has one, so
                        // the Dart side can tell a network failure from, say,
                        // an unrecognised module.
                        val code = (error as? SplitInstallException)?.errorCode
                        Log.e(TAG, "install $module failed (code=$code)", error)
                        result.error(
                            "install_failed",
                            error.message ?: "startInstall failed",
                            code,
                        )
                    }
            }

            "uninstall" -> {
                val module = call.argument<String>("module")
                if (module == null) {
                    result.error("bad_args", "module is required", null)
                    return
                }
                // Play defers the actual removal to an idle moment; the task
                // completing only means the request was accepted.
                manager.deferredUninstall(listOf(module))
                    .addOnSuccessListener {
                        Log.i(TAG, "uninstall $module requested")
                        result.success(true)
                    }
                    .addOnFailureListener { error ->
                        Log.e(TAG, "uninstall $module failed", error)
                        result.error(
                            "uninstall_failed",
                            error.message ?: "deferredUninstall failed",
                            null,
                        )
                    }
            }

            "cancel" -> {
                val sessionId = call.argument<Int>("sessionId")
                if (sessionId == null) {
                    result.error("bad_args", "sessionId is required", null)
                    return
                }
                manager.cancelInstall(sessionId)
                    .addOnSuccessListener { result.success(true) }
                    .addOnFailureListener { result.success(false) }
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun emit(state: SplitInstallSessionState) {
        val sink = events ?: return
        sink.success(
            mapOf(
                "sessionId" to state.sessionId(),
                "status" to statusName(state.status()),
                "errorCode" to state.errorCode(),
                "bytesDownloaded" to state.bytesDownloaded(),
                "totalBytesToDownload" to state.totalBytesToDownload(),
                "modules" to state.moduleNames(),
            ),
        )
    }

    /**
     * FlutterActivity extends android.app.Activity, not ComponentActivity, so
     * there is no ActivityResultLauncher to hand Play — this uses the
     * Activity + requestCode overload instead. The result itself is ignored:
     * whether the user accepted or declined arrives through
     * SplitInstallStateUpdatedListener like every other state change. If the
     * activity is gone there is nothing to show the dialog on; the session
     * stays pending and the Dart side's own timeout ends the wait.
     */
    private fun requestUserConfirmation(state: SplitInstallSessionState) {
        val host = activity ?: return
        runCatching {
            manager.startConfirmationDialogForResult(state, host, CONFIRMATION_REQUEST_CODE)
        }
    }

    private fun statusName(status: Int): String = when (status) {
        SplitInstallSessionStatus.PENDING -> "pending"
        SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION -> "requiresUserConfirmation"
        SplitInstallSessionStatus.DOWNLOADING -> "downloading"
        SplitInstallSessionStatus.DOWNLOADED -> "downloaded"
        SplitInstallSessionStatus.INSTALLING -> "installing"
        SplitInstallSessionStatus.INSTALLED -> "installed"
        SplitInstallSessionStatus.FAILED -> "failed"
        SplitInstallSessionStatus.CANCELING -> "canceling"
        SplitInstallSessionStatus.CANCELED -> "canceled"
        else -> "unknown"
    }
}
