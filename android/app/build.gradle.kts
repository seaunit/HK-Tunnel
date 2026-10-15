import java.text.SimpleDateFormat
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Date
import java.util.Locale
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val versionPropertiesFile = rootProject.file("version.properties")
val versionProperties = Properties()
versionPropertiesFile.inputStream().use { versionProperties.load(it) }
val releaseName = versionProperties.getProperty("versionName", "1.0")

// Android only needs versionCode to grow for an update to be accepted, so it is
// taken from the build clock rather than a counter that is easy to forget to
// bump. Minutes since 2026-01-01 UTC: monotonic, unique per minute, and small
// enough to stay well inside the versionCode limit.
val versionEpochMs = LocalDate.of(2026, 1, 1)
    .atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
val autoVersionCode = ((System.currentTimeMillis() - versionEpochMs) / 60_000L).toInt()
val buildStamp = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date())

android {
    namespace = "com.hktunnel.tunnel"
    compileSdk = 36
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "com.hktunnel.tunnel"
        minSdk = 26
        targetSdk = 34
        versionCode = autoVersionCode
        versionName = releaseName
        buildConfigField("String", "BUILD_STAMP", "\"$buildStamp\"")

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    externalNativeBuild {
        ndkBuild {
            path = file("src/main/jni/Android.mk")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Personal-side tool: signed with the debug key so it installs without setup.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.github.mwiede:jsch:0.2.21")
}
