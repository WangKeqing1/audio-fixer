import com.android.build.api.dsl.ApplicationExtension
import java.io.File

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

// An opt-in, synthetic-only runtime probe uses a second APK without INTERNET
// to prove already-downloaded models translate without network access.
val audioFixerTranslationProbe = providers.gradleProperty("audioFixerTranslationProbe")
    .map { it.equals("true", ignoreCase = true) }
    .getOrElse(false)
val audioFixerTranslationOffline = providers.gradleProperty("audioFixerTranslationOffline")
    .map { it.equals("true", ignoreCase = true) }
    .getOrElse(false)
require(!audioFixerTranslationProbe || audioFixerQa) {
    "The translation probe requires the isolated audioFixerQa application."
}
require(!audioFixerTranslationOffline || (audioFixerTranslationProbe && audioFixerQa)) {
    "The offline translation manifest is allowed only in an isolated QA translation probe."
}
if (audioFixerTranslationProbe) {
    val target = providers.gradleProperty("target").orNull
    val targetFile = target?.let {
        val path = File(it)
        if (path.isAbsolute) path else rootProject.file("../$it")
    }
    require(targetFile?.canonicalFile == rootProject.file("../tool/native_translation_probe.dart").canonicalFile) {
        "The translation probe flags require --target tool/native_translation_probe.dart."
    }
}

// Keep a real android { namespace = ... } block for Flutter's source parser,
// while resolving configuration through AGP's public interface rather than the
// deprecated generated BaseAppModuleExtension accessor.
fun android(block: ApplicationExtension.() -> Unit) {
    extensions.configure<ApplicationExtension> { block(this) }
}

android {
    namespace = "com.audiofixer.audio_fixer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions.apply {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig.apply {
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

    buildTypes.configureEach {
        if (audioFixerQa) {
            applicationIdSuffix = ".qa.v030"
            versionNameSuffix = "-qa"
            manifestPlaceholders["audioFixerLabel"] = "Audio Fixer QA 0.3"
        }
    }
    buildTypes.named("release") {
        // TODO: Add your own signing config for the release build.
        // Signing with the debug keys for now, so `flutter run --release` works.
        signingConfig = signingConfigs.getByName("debug")
    }

    sourceSets.configureEach {
        if (audioFixerTranslationOffline && name in setOf("debug", "profile", "release")) {
            // A higher-priority build-type overlay removes INTERNET from the
            // main manifest and every transitive library manifest.
            manifest.srcFile("src/translationProbeOffline/AndroidManifest.xml")
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

dependencies {
    // Models are downloaded explicitly over Wi-Fi; lyric inference stays on device.
    implementation("com.google.mlkit:translate:17.0.3")
    // Bundle identification so identifying a language never downloads its model.
    implementation("com.google.mlkit:language-id:17.0.6")
}
