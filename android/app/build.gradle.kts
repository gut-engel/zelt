import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives outside the repository (see `make keys`):
// ~/.config/zelt-signing/keystore.properties, or $ZELT_SIGNING_PROPS.
// Without it, release builds fall back to the debug key so anyone can build.
val zeltSigning = Properties().apply {
    val path = System.getenv("ZELT_SIGNING_PROPS")
        ?: "${System.getProperty("user.home")}/.config/zelt-signing/keystore.properties"
    val f = file(path)
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.zelt.zelt"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.zelt.zelt"
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
    }

    signingConfigs {
        if (zeltSigning.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(zeltSigning.getProperty("storeFile"))
                storePassword = zeltSigning.getProperty("storePassword")
                keyAlias = zeltSigning.getProperty("keyAlias")
                keyPassword = zeltSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
