plugins {
    id("com.android.application")
}

android {
    namespace = "com.example.nanotest"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.nanotest"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }
}

dependencies {
    implementation("com.google.mlkit:genai-prompt:1.0.0-beta4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
