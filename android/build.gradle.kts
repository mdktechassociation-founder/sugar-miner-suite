// Gradle module for the SDK's Android side. Versions mirror the Flutter 3.47
// app template (Gradle 9.3.1 / AGP 9.1.0 / Kotlin 2.4.0) — the host app supplies
// the plugin classpath, so nothing is re-declared here.
group = "com.mdk.sugarminer.sdk"
version = "1.0.0"

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mdk.sugarminer.sdk"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }

    // The C hashing core. Same files the desktop self-test compiles, so the
    // library in the APK is bit-for-bit the one the tests verified.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
