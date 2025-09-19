plugins {
	id("com.android.library")
	kotlin("android")
	kotlin("plugin.serialization") version "1.9.24"
}

android {
	namespace = "org.kisr.sdk"
	compileSdk = 34

	defaultConfig {
		minSdk = 23
		targetSdk = 34
		consumerProguardFiles("consumer-rules.pro")
	}

	buildFeatures {
		compose = true
	}
	composeOptions {
		kotlinCompilerExtensionVersion = "1.5.14"
	}

	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_11
		targetCompatibility = JavaVersion.VERSION_11
	}

	kotlinOptions {
		jvmTarget = "11"
		freeCompilerArgs += listOf("-Xjvm-default=all")
	}
}

dependencies {
	implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
	// Optional crypto backend via LazySodium (libsodium)
	implementation("com.goterl:lazysodium-android:5.1.0")
	implementation("net.java.dev.jna:jna:5.13.0@aar")

	// Compose UI for QR view
	implementation("androidx.compose.ui:ui:1.6.8")
	implementation("androidx.compose.foundation:foundation:1.6.8")

	// ZXing for QR generation
	implementation("com.google.zxing:core:3.5.3")

	// Rhino JS engine for example JS bridge
	implementation("org.mozilla:rhino:1.7.14")
}
