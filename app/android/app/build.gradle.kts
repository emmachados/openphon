import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Local signing configuration is never committed. CI can select a separate
// properties file through OPENPHON_ANDROID_KEY_PROPERTIES.
val signingPropertiesFile = file(
    System.getenv("OPENPHON_ANDROID_KEY_PROPERTIES")
        ?: rootProject.file("key.properties").absolutePath
)
val keystoreProperties = Properties().apply {
    if (signingPropertiesFile.isFile) signingPropertiesFile.inputStream().use { load(it) }
}
val signingFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val signingComplete = signingFields.all { !keystoreProperties.getProperty(it).isNullOrBlank() }
val releaseKeystore = if (signingComplete) {
    val configured = File(keystoreProperties.getProperty("storeFile"))
    if (configured.isAbsolute) configured else File(signingPropertiesFile.parentFile, configured.path)
} else null
val releaseSigningReady = signingComplete && releaseKeystore?.isFile == true
// This opt-in creates an unsigned artifact solely for packaging verification.
val unsignedRelease = System.getenv("OPENPHON_UNSIGNED_RELEASE") == "1"

gradle.taskGraph.whenReady {
    val includesRelease = allTasks.any { it.project == project && it.name.contains("Release") }
    if (includesRelease && !unsignedRelease && !releaseSigningReady) {
        throw GradleException(
            "Release signing is unavailable. Supply a valid Android signing properties file " +
            "and its existing keystore. OPENPHON_UNSIGNED_RELEASE=1 is only for unsigned build verification."
        )
    }
}

android {
    namespace = "app.openphon.openphon"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.openphon.openphon"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningReady && !unsignedRelease) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = releaseKeystore
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseSigningReady && !unsignedRelease) {
                signingConfigs.getByName("release")
            } else {
                null
            }
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
