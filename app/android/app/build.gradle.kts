import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, read from android/key.properties, which is gitignored.
//
// A signing key is the app's identity: it is what App Links verify against and
// what Play uses to decide that an update is from the same author. It cannot be
// rotated after publishing without orphaning every existing install, so it is
// the one secret in this project that must never be committed.
//
// See android/key.properties.example for how to make one.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "xyz.usetip.tip"
    // flutter_secure_storage 11 requires API 37. Staying on 11 rather than
    // downgrading to 10.x is deliberate: the known silent-data-loss bug in
    // 11 is on the 10-to-11 upgrade path, so a new wallet that starts here
    // never has to migrate real seeds across it.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "xyz.usetip.tip"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")
                    ?.let { rootProject.file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Falls back to the debug key so `flutter run --release` still
                // works on a fresh clone, and says so loudly rather than
                // producing an artifact that looks shippable and is not.
                //
                // A debug-signed release cannot go to Play, and every Android
                // debug keystore uses the password "android", so an App Link
                // delegated to one is delegated to a key that is not a secret.
                // site/.well-known/assetlinks.json currently publishes exactly
                // this fingerprint; it has to be replaced with the real one
                // before tip:// links can be trusted on Android.
                logger.warn(
                    "\n  WARNING: signing the release build with the DEBUG key." +
                    "\n  Not shippable, and not a real app identity." +
                    "\n  See android/key.properties.example.\n"
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
