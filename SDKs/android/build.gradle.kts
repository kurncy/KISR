buildscript {
	dependencies {
		classpath("com.android.tools.build:gradle:8.6.0")
		classpath(kotlin("gradle-plugin", version = "1.9.24"))
		classpath("org.jetbrains.kotlin:kotlin-serialization:1.9.24")
	}
}

allprojects {
	repositories {
		google()
		mavenCentral()
	}
}
