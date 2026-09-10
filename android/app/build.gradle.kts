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

// Required by the on-demand province maps, and only by them: it provides both
// SplitInstallManager (PmtilesDeliveryBridge) and SplitCompat
// (SuelosArApplication, MainActivity, PmtilesAssetRefresher).
//
// Deliberately the modern split artifact and NOT the monolithic
// com.google.android.play:core, which Google Play rejects for targetSdk 34+.
// Nothing here can use com.google.android.play:core again: the app would be
// refused at upload. That constraint is what rules out Flutter's own
// deferred-components stack — PlayStoreDeferredComponentManager is compiled
// against the legacy com.google.android.play.core.tasks.Task and fails with
// NoSuchMethodError on startInstall() against this artifact, and shimming the
// old package is impossible (D8 rejects the duplicate SplitInstallManager).
// Both were reproduced on a clean emulator; the native bridge exists because
// of it. Revisit only if the Flutter engine itself migrates off play:core —
// it had not as of 3.47.2, nor on beta or main.
dependencies {
    implementation("com.google.android.play:feature-delivery:2.1.0")
}
