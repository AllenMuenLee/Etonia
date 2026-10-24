plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.etonia.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.etonia.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
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

dependencies {
    // Jetpack Ink owns the latency-critical wet-ink layer. Keep the preview
    // native while Flutter remains the document model and dry-ink renderer.
    implementation("androidx.ink:ink-authoring:1.1.0-alpha10")
    implementation("androidx.ink:ink-brush:1.1.0-alpha10")
    implementation("androidx.ink:ink-geometry:1.1.0-alpha10")
    implementation("androidx.ink:ink-nativeloader:1.1.0-alpha10")
    implementation("androidx.ink:ink-rendering:1.1.0-alpha10")
    implementation("androidx.ink:ink-strokes:1.1.0-alpha10")
    implementation("androidx.input:input-motionprediction:1.0.0")
    // On-device recognition for handwriting written in AI mode. Digital ink
    // reads the strokes themselves; its language model is downloaded on
    // first use. Until then, text recognition, whose Latin model is
    // bundled, reads a picture of them.
    implementation("com.google.mlkit:digital-ink-recognition:18.1.0")
    implementation("com.google.mlkit:text-recognition:16.0.1")
}
