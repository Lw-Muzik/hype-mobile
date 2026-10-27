import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase for production builds. google-services turns google-services.json into
// the resources native Analytics reads (without them it logs "Missing google_app_id"
// and stays off), and Crashlytics adds the build id and uploads R8 mapping files.
// Only x.a.zix is registered in Firebase, so dev copies (x.a.zix.dev) skip both.
if (!project.hasProperty("dev")) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val onnxRuntimeDir = layout.buildDirectory.dir("onnxruntime")

android {
    namespace = "x.a.zix"
    compileSdk = flutter.compileSdkVersion
    // Pin to NDK r28+, which links native libs with 16 KB page alignment by
    // default (required for Android 15+ / 16 KB-page devices). Leaving this as
    // flutter.ndkVersion can resolve to an older NDK that produces 4 KB-aligned
    // libs.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // libonnxruntime.so arrives with the AAR; CMake links against the copy
    // extracted below, so make sure only one ends up in the APK.
    packaging {
        jniLibs {
            pickFirsts += listOf("**/libonnxruntime.so")
            // The AAR's Java-API JNI shim: unused, the engine calls the C API.
            excludes += listOf("**/libonnxruntime4j_jni.so")
        }
    }

    // `flutter build apk --android-project-arg=dev=true` builds a side-by-side
    // test copy ("Hype Muzik Dev", x.a.zix.dev). The Play Store install is
    // signed by Google Play, so no locally built APK can update it; uninstalling
    // it instead would wipe the device's library, history and logins.
    val devCopy = project.hasProperty("dev")

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (devCopy) "x.a.zix.dev" else "x.a.zix"
        manifestPlaceholders["appLabel"] = if (devCopy) "Hype Muzik Dev" else "Hype Muzik"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 34
        versionName = flutter.versionName
        manifestPlaceholders["appAuthRedirectScheme"] = "x.a.zix"

        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }

        externalNativeBuild {
            cmake {
                // Headers + per-ABI libonnxruntime.so for the live-stem engine.
                arguments += listOf("-DORT_DIR=" + onnxRuntimeDir.get().asFile.absolutePath)
            }
        }
    }
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
             // The dev copy is always debug-signed so a release-mode test build installs over the
             // existing x.a.zix.dev without uninstalling it (which would wipe its data).
             signingConfig = if (devCopy) signingConfigs.getByName("debug") else signingConfigs.getByName("release")
             isMinifyEnabled = true
             isShrinkResources = false
             proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// Force transitive native dependencies to versions whose bundled .so files are
// 16 KB page-aligned (Android 15+/16 KB-page devices, Play upload requirement).
// Evidence: the graph was resolving CameraX 1.3.3 and ML Kit barcode 17.2.0,
// both 4 KB-aligned. These pins move them to the aligned releases. DataStore is
// pinned to 1.1.7 because its newer 1.2.x line regressed 16 KB alignment.
//
// CameraX must stay >= 1.6.1: mobile_scanner 7.2.0 is compiled against it, and
// in 1.6.x `Camera2Config` became a Kotlin class with a companion object. Forcing
// it back to 1.5.3 — where that field does not exist — resolves and compiles
// cleanly and then throws NoSuchFieldError for Camera2Config$Companion the moment
// the plugin attaches to the activity, i.e. at launch. A `force` that lowers a
// version below what a dependency was compiled against is invisible until runtime.
configurations.all {
    resolutionStrategy {
        force(
            "androidx.camera:camera-core:1.6.1",
            "androidx.camera:camera-camera2:1.6.1",
            "androidx.camera:camera-lifecycle:1.6.1",
            "androidx.camera:camera-view:1.6.1",
            "com.google.mlkit:barcode-scanning:17.3.0",
            "com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1",
            "androidx.datastore:datastore:1.1.7",
            "androidx.datastore:datastore-core:1.1.7",
            "androidx.datastore:datastore-core-android:1.1.7",
            "androidx.datastore:datastore-preferences:1.1.7",
            "androidx.datastore:datastore-preferences-core:1.1.7",
        )
    }
}

// ONNX Runtime for live stem separation (cpp/stems). The AAR ships headers and
// per-ABI libonnxruntime.so but no prefab metadata, so the native build gets
// them from a copy extracted here. 1.31.0's libraries are 16 KB page-aligned.
val onnxRuntimeVersion = "1.31.0"
val onnxRuntimeAar: Configuration by configurations.creating
val extractOnnxRuntime by tasks.registering(Copy::class) {
    from({ zipTree(onnxRuntimeAar.singleFile) }) {
        include("headers/**", "jni/**")
    }
    into(onnxRuntimeDir)
}
tasks.matching {
    it.name.startsWith("configureCMake") || it.name.startsWith("buildCMake") ||
        it.name.startsWith("generateJsonModel")
}.configureEach { dependsOn(extractOnnxRuntime) }

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:$onnxRuntimeVersion")
    onnxRuntimeAar("com.microsoft.onnxruntime:onnxruntime-android:$onnxRuntimeVersion@aar")
    implementation("com.mpatric:mp3agic:0.9.1")
    implementation("net.jthink:jaudiotagger:3.0.1")
    implementation("androidx.media3:media3-exoplayer:1.4.1")
}

flutter {
    source = "../.."
}
