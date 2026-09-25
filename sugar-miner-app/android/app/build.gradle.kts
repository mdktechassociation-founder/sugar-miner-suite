plugins {
    id("com.android.application")
    // needed for MainActivity.kt; already version-pinned in settings.gradle.kts
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mdk.sugarminer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.mdk.sugarminer"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ---- the native hashing core -------------------------------------------
    // CMake compiles native/yespower/ into libyespower.so for every ABI that
    // gets built, and packages it into the APK. Dart finds it by name over FFI.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // Debug signing so a CI-built APK installs straight away. Swap in
            // your own keystore before publishing anywhere.
            signingConfig = signingConfigs.getByName("debug")
            // Shrinking stays off on purpose: the native symbols and the
            // background service are reached by name, so a stripped build would
            // only fail at runtime — the worst place to find out.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
