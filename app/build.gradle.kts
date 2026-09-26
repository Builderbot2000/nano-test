plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
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
    implementation("com.google.code.gson:gson:2.14.0")
    // Generates the schema providers for @Generable classes (structured output).
    ksp("com.google.mlkit:genai-schema-compiler:1.0.0-alpha1")
}
