import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.shotasakaguchi.mochittotsumitsumi"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.shotasakaguchi.mochittotsumitsumi"
        minSdk = 26
        targetSdk = 36
        // Increment versionCode for every Google Play upload
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // Share the exact same game file with the iOS app
    sourceSets["main"].assets.srcDir(rootProject.file("../MochittoTsumitsumi/web"))

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.core:core-ktx:1.16.0")
}
