package com.example.suelosar

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (BuildConfig.DISABLE_GEOLOCATOR_DIAGNOSTIC) {
            registerPluginsWithoutGeolocator(flutterEngine)
        } else {
            GeneratedPluginRegistrant.registerWith(flutterEngine)
        }
    }

    // This list mirrors Flutter's generated registrant except GeolocatorPlugin.
    // It exists only to isolate the native location plugin during ANR diagnosis.
    private fun registerPluginsWithoutGeolocator(flutterEngine: FlutterEngine) {
        flutterEngine.plugins.add(
            dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin(),
        )
        flutterEngine.plugins.add(
            dev.flutter.plugins.integration_test.IntegrationTestPlugin(),
        )
        flutterEngine.plugins.add(com.github.dart_lang.jni.JniPlugin())
        flutterEngine.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
        flutterEngine.plugins.add(
            dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin(),
        )
        flutterEngine.plugins.add(dev.fluttercommunity.plus.share.SharePlusPlugin())
        flutterEngine.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
        flutterEngine.plugins.add(
            com.syncfusion.flutter.pdfviewer.SyncfusionFlutterPdfViewerPlugin(),
        )
        flutterEngine.plugins.add(io.flutter.plugins.urllauncher.UrlLauncherPlugin())
    }
}
