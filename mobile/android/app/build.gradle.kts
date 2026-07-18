import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val releaseSigningEnvironment = mapOf(
    "storeFile" to System.getenv("ANDROID_KEYSTORE_PATH"),
    "storePassword" to System.getenv("ANDROID_KEYSTORE_PASSWORD"),
    "keyAlias" to System.getenv("ANDROID_KEY_ALIAS"),
    "keyPassword" to System.getenv("ANDROID_KEY_PASSWORD"),
)
val hasEnvironmentReleaseSigning =
    releaseSigningEnvironment.values.any { !it.isNullOrBlank() }

if (hasEnvironmentReleaseSigning) {
    val missing = releaseSigningEnvironment
        .filterValues { it.isNullOrBlank() }
        .keys
    check(missing.isEmpty()) {
        "Incomplete environment-based Android release signing configuration: " +
            "missing ${missing.joinToString()}"
    }
}

val hasReleaseSigning = hasEnvironmentReleaseSigning || keystorePropertiesFile.exists()

fun requiredReleaseSigningValue(name: String): String {
    if (hasEnvironmentReleaseSigning) {
        return releaseSigningEnvironment.getValue(name)!!
    }
    return keystoreProperties.getProperty(name)
        ?: error("Missing '$name' in ${keystorePropertiesFile.path}")
}

android {
    namespace = "dev.lystic.radar_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.lystic.radar"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(requiredReleaseSigningValue("storeFile"))
                storePassword = requiredReleaseSigningValue("storePassword")
                keyAlias = requiredReleaseSigningValue("keyAlias")
                keyPassword = requiredReleaseSigningValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // A missing signing environment/key.properties intentionally
            // produces an unsigned artifact; never fall back to the debug key.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}
