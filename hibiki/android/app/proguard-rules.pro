# VLC native library
-keep class org.videolan.libvlc.** { *; }

# Flutter engine & embedding
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Hibiki native channels & providers
-keep class app.hibiki.reader.** { *; }

# audio_service background isolate
-keep class com.ryanheise.audioservice.** { *; }

# InAppWebView
-keep class com.pichillilorenzo.flutter_inappwebview.** { *; }

# Drift / SQLite (moor_ffi)
-keep class com.tekartik.sqflite.** { *; }

# Kotlin metadata for reflection-based plugins
-keepattributes *Annotation*
-keep class kotlin.Metadata { *; }

# Keep native method signatures for JNI / FFI
-keepclasseswithmembernames class * {
    native <methods>;
}

# Play Core split install (referenced by Flutter engine but not bundled)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
