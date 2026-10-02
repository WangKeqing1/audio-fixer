plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Versioned opt-in QA identity: CI test signers cannot replace older local QA
// installs safely. Keep the previous QA package/private data alongside 0.3.
// Normal builds keep the application's existing identity.
val audioFixerQa = providers.gradleProperty("audioFixerQa")
    .map { it.equals("true", ignoreCase = true) }
    .getOrElse(false)

android {
    namespace = "com.audiofixer.audio_fixer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.audiofixer.audio_fixer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["audioFixerLabel"] = "Audio Fixer"
    }

    buildTypes {
        configureEach {
            if (audioFixerQa) {
                applicationIdSuffix = ".qa.v030"
                versionNameSuffix = "-qa"
                manifestPlaceholders["audioFixerLabel"] = "Audio Fixer QA 0.3"
            }
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
