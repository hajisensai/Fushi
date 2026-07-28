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
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }

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
-keep class eu.kanade.tachiyomi.source.** { *; }
-keep class eu.kanade.tachiyomi.network.** { *; }
-keep class tachiyomi.core.common.util.lang.** { *; }
-keep class mihon.core.common.extensions.** { *; }
-keep class uy.kohesive.injekt.** { *; }
# Third-party extension bytecode calls these host libraries dynamically, so
# R8 cannot infer the reachable API surface from Hibiki itself.
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class org.jsoup.** { *; }
-keep class rx.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class androidx.preference.** { *; }
-keep class androidx.compose.runtime.** { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
