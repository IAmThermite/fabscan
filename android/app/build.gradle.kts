import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Shared dev signing: if android/key.properties exists, sign every build with the
// committed-out-of-git fabscan-shared.jks so the installed app is never force-uninstalled
// on rebuilds or across machines. If it's absent, fall back to the per-machine debug keys.
val keystorePropertiesFile = rootProject.file("key.properties")
val useSharedSigning = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (useSharedSigning) FileInputStream(keystorePropertiesFile).use { load(it) }
}

android {
    namespace = "com.example.fabscan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.fabscan"
        // opencv_dart + flutter_tesseract_ocr + camera need a modern minSdk.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (useSharedSigning) {
        signingConfigs {
            create("shared") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        // Sign debug and release with the same key so the on-device app updates in place
        // instead of being uninstalled/reinstalled. Falls back to debug keys if key.properties
        // is missing (e.g. a fresh machine that hasn't copied it yet).
        val signing = if (useSharedSigning) {
            signingConfigs.getByName("shared")
        } else {
            signingConfigs.getByName("debug")
        }
        release {
            signingConfig = signing
        }
        debug {
            signingConfig = signing
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
