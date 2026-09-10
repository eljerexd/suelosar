# mobile_scanner 7.2.0 only keeps the direct com.google.mlkit package.
# Barcode component registrars live in nested packages and are loaded at runtime.
-keep class com.google.mlkit.** { *; }

# Flutter's engine ships PlayStoreDeferredComponentManager, which is compiled
# against the legacy com.google.android.play:core and references
# com.google.android.play.core.tasks.* — classes that do not exist in the
# modern feature-delivery library this app uses instead. Nothing reaches that
# manager (the manifest names SuelosArApplication, not
# FlutterPlayStoreSplitApplication, and no Dart code calls DeferredComponent),
# so R8 strips it; these silence the missing-reference warnings it emits on the
# way. Dropping the legacy artifact is the point: Google Play rejects it for
# targetSdk 34+.
-dontwarn com.google.android.play.core.tasks.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.PlayStoreDeferredComponentManager
-dontwarn io.flutter.embedding.engine.deferredcomponents.PlayStoreDeferredComponentManager$**
-dontwarn io.flutter.embedding.android.FlutterPlayStoreSplitApplication
