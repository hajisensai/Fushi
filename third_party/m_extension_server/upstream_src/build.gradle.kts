import org.gradle.kotlin.dsl.withType
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlinter) apply false
    alias(libs.plugins.buildconfig) apply false
    alias(libs.plugins.shadowjar) apply false
}

allprojects {
    group = "mangayomi"
    version = "1.0"

    repositories {
        mavenCentral()
        google()
        maven("https://github.com/Suwayomi/Suwayomi-Server/raw/android-jar/")
        maven("https://jogamp.org/deployment/maven")
        maven("https://maven.google.com/")
        maven("https://jitpack.io")
        maven("https://dl.google.com/dl/android/maven2/")
        maven("https://repo1.maven.org/maven2/")
        maven("https://oss.sonatype.org/content/repositories/snapshots/")
    }
}

val projects = listOf(
    project(":server")
)

configure(projects) {
    apply(plugin = "org.jetbrains.kotlin.jvm")

    java {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    tasks.withType<KotlinCompile> {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_21)
        }
    }

    dependencies {
        implementation(rootProject.libs.bundles.common)
    }
}
