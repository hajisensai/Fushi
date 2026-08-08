# VLC native library
-keep class org.videolan.libvlc.** { *; }

# Flutter engine & embedding
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Fushi native channels & providers.
# This package filter MUST track applicationId / namespace in android/app/build.gradle.
# The W8 directory rename moved applicationId from app.hibiki.reader to app.fushi.reader
# but left this keep rule pointing at the old package, so it matched zero classes and
# every app-side Kotlin/Java class entered R8's optimization surface for the first time.
# R8 then horizontally merged the anonymous FullTypeReference subclasses that Injekt's
# reified `addSingleton` / `addSingletonFactory` inline into MihonChannelHandler, which
# made getGenericSuperclass() stop being a ParameterizedType and crashed
# MainActivity.onCreate with "TypeReference constructed without actual type information".
-keep class app.fushi.reader.** { *; }

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

# Injekt reflective generics backstop (package-independent, survives future renames).
# `addSingleton<T>()` / `addSingletonFactory<T>()` are reified inline functions that
# expand to `object : FullTypeReference<T>() {}` at the call site, and Injekt reads the
# type argument back out via javaClass.genericSuperclass. R8's horizontal/vertical class
# merging destroys that superclass signature. allowshrinking+allowobfuscation keeps the
# classes eligible for removal and renaming (no size regression) while opting them out of
# class merging and forcing Signature retention -- the same pattern R8 ships for
# Gson's TypeToken.
-keep,allowshrinking,allowobfuscation class uy.kohesive.injekt.api.TypeReference
-keep,allowshrinking,allowobfuscation class uy.kohesive.injekt.api.FullTypeReference
-keep,allowshrinking,allowobfuscation class * extends uy.kohesive.injekt.api.FullTypeReference
