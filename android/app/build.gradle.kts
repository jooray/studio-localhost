import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: the publisher key described by ~/.apk-signing-keystore/signing.properties
// (outside the repo), overridable with STUDIO_SIGNING_PROPERTIES. Without it, release builds
// fall back to the debug key so `flutter run --release` still works.
val keystoreProperties = Properties().apply {
    val path = System.getenv("STUDIO_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.apk-signing-keystore/signing.properties"
    val file = File(path)
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "io.github.jooray.localhoststudio"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.jooray.localhoststudio"
        minSdk = 34
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // arm64-v8a only: the engine is tuned for Armv8.6+ phone cores.
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                abiFilters += "arm64-v8a"
                arguments += listOf("-DANDROID_STL=c++_static", "-DCMAKE_BUILD_TYPE=Release", "-DYUE2_VULKAN=OFF")
            }
        }
    }

    // yue2.cpp (git submodule) + the JNI wrapper; the hooks patch is applied by CMake.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (keystoreProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // The engine is unusably slow at -O0; build native code optimized in debug too.
            externalNativeBuild { cmake { arguments += "-DCMAKE_BUILD_TYPE=Release" } }
        }
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    packaging {
        jniLibs { useLegacyPackaging = false }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    // Song playback (AudioPlayerChannel). Pure Java/Kotlin; replaces media_kit/libmpv on Android.
    implementation("androidx.media3:media3-exoplayer:1.8.0")
}

flutter {
    source = "../.."
}
