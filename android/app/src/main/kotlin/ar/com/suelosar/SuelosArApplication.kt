package ar.com.suelosar

import com.google.android.play.core.splitcompat.SplitCompatApplication

/**
 * Application entry point, present for exactly one reason: Play Feature
 * Delivery.
 *
 * A module installed at runtime is only visible to the running process once
 * SplitCompat has been installed into it — without that, Play can download and
 * install `buenosAiresPmtiles` perfectly and its assets still will not resolve.
 * [SplitCompatApplication] does that in `attachBaseContext`, so subclassing it
 * is most of the implementation; the rest is [PmtilesAssetRefresher], which
 * covers modules that arrive after the Flutter engine has already started.
 *
 * Deliberately NOT io.flutter.embedding.android.FlutterPlayStoreSplitApplication,
 * which is what Flutter's deferred-components documentation recommends. That
 * class also installs Flutter's own PlayStoreDeferredComponentManager, and that
 * manager is compiled against the legacy com.google.android.play:core:1.10.3 —
 * the artifact Google Play refuses for targetSdk 34+. Since this app drives
 * Play Feature Delivery itself through [PmtilesDeliveryBridge] and never calls
 * Flutter's DeferredComponent API, nothing needs that manager, and dropping it
 * is what lets the legacy dependency go.
 */
class SuelosArApplication : SplitCompatApplication() {
    override fun onCreate() {
        super.onCreate()
        // Before any FlutterActivity exists, so the injector is still unread.
        PmtilesAssetRefresher.register()
    }
}
