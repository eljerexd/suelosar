import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val disableGeolocatorDiagnostic = providers
    .gradleProperty("disableGeolocatorDiagnostic")
    .map(String::toBoolean)
    .getOrElse(false)

android {
    namespace = "ar.com.suelosar"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ar.com.suelosar"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        buildConfigField(
            "boolean",
            "DISABLE_GEOLOCATOR_DIAGNOSTIC",
            disableGeolocatorDiagnostic.toString(),
        )

        // Nombre de app por defecto (usado por la variante "prod"). La
        // variante "beta" lo sobreescribe con su propio resValue más abajo.
        // AndroidManifest.xml referencia "@string/app_name" en vez de un
        // literal para que esto funcione.
        resValue("string", "app_name", "SuelosAR")
    }

    // Variante Beta (ar.com.suelosar.beta) para poder instalarla junto a la
    // versión normal (ar.com.suelosar) en el mismo dispositivo, y así probar
    // MapLibreEngine sin afectar la app de Google Play. "prod" no agrega
    // ningún sufijo, por lo que mantiene exactamente el applicationId y el
    // comportamiento actuales.
    flavorDimensions += "env"
    productFlavors {
        create("prod") {
            dimension = "env"
        }
        create("beta") {
            dimension = "env"
            applicationIdSuffix = ".beta"
            versionNameSuffix = "-beta"
            resValue("string", "app_name", "SuelosAR Beta")
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles("proguard-rules.pro")
        }
    }

    // Fase 11B/12A: both Santa Fe's and Buenos Aires' soil-polygon PMTiles
    // are assets-only deferred components (see pubspec.yaml), delivered on
    // demand via Play Feature/Asset Delivery instead of shipping inside the
    // base module.
    dynamicFeatures += setOf(":santaFePmtiles", ":buenosAiresPmtiles")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
flutter {
    source = "../.."
}

// La variante Beta usa el applicationId "ar.com.suelosar.beta", que no
// figura en google-services.json (solo tiene registrado "ar.com.suelosar"),
// así que las tareas nativas de Google Services/Crashlytics fallarían para
// Beta con "No matching client found for package name". Esto NO afecta a
// Firebase en tiempo de ejecución: lib/main.dart inicializa Firebase con
// FirebaseOptions explícitas (firebase_options.dart), no con los recursos
// que generan estas tareas. Deshabilitarlas es reversible (basta con borrar
// este bloque) y no toca google-services.json ni la config de producción.
afterEvaluate {
    tasks.matching {
        it.name.contains("Beta") &&
            (it.name.contains("GoogleServices") || it.name.contains("Crashlytics"))
    }.configureEach {
        enabled = false
    }
}

// Required by Play Store Deferred Components, and only by them.
//
// AndroidManifest declares io.flutter.embedding.android.FlutterPlayStoreSplitApplication
// as the application class; that class extends Play Core's
// SplitCompatApplication, which calls SplitCompat.install() so an on-demand
// module installed at runtime becomes visible to this process. Without the
// dependency the superclass is absent, R8 drops the Flutter class with it, and
// the app dies on launch with ClassNotFoundException before any Dart runs —
// reproduced on a clean emulator with bundletool --local-testing.
//
// The monolithic com.google.android.play:core, NOT the newer split artifacts.
// Flutter 3.47.2's PlayStoreDeferredComponentManager is compiled against the
// legacy surface: it calls SplitInstallManager.startInstall() expecting a
// com.google.android.play.core.tasks.Task. feature-delivery:2.1.0 returns a
// com.google.android.gms.tasks.Task instead, so the app builds and launches
// but dies the moment a download is requested, with
// NoSuchMethodError: No interface method startInstall(...) — reproduced on a
// clean emulator. Flutter's own deferred-components fixture pins this same
// artifact. Revisit if the engine ever migrates.
dependencies {
    implementation("com.google.android.play:core:1.10.3")
}
