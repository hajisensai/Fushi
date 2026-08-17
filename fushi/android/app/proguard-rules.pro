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
# ---------------------------------------------------------------------------
# Mihon 扩展宿主 ABI（BUG-1702）
#
# Mihon 扩展 APK 是**独立编译**的第三方 dex：它把宿主提供的一切（Kotlin 运行时、
# okhttp、jsoup、rx、injekt、source-api……）都当 compileOnly，字节码里写死的是
# **未混淆的原名**。所以凡是扩展可能引用的包，宿主 APK 里必须以原名原样存在——
# R8 一旦重命名或删除，扩展加载即 NoClassDefFoundError。
#
# 这份清单漏一个包就是一整类扩展装不上，且 debug 构建（不 minify）永远复现不了，
# 只在 release 上必现。加依赖时必须同步这里，守卫见
# fushi/test/media/manga/mihon_host_abi_keep_guard_test.dart。
# 对照上游 Mihon app/proguard-rules.pro 的 "Keep common dependencies used in
# extensions" 区块——Mihon 自己走 -dontobfuscate 全保，Fushi 有混淆，只能逐包 keep。
# ---------------------------------------------------------------------------
-keep class eu.kanade.tachiyomi.source.** { *; }
-keep class eu.kanade.tachiyomi.network.** { *; }
# asJsoup()/awaitSingle() 等扩展解析必用的顶层函数（JsoupExtensionsKt / RxExtension）。
# 宿主自身一次都不调，漏 keep 时 R8 会把整个包删掉。
-keep class eu.kanade.tachiyomi.util.** { *; }
-keep class tachiyomi.core.common.util.lang.** { *; }
-keep class mihon.core.common.extensions.** { *; }
-keep class uy.kohesive.injekt.** { *; }
# Third-party extension bytecode calls these host libraries dynamically, so
# R8 cannot infer the reachable API surface from Fushi itself.
# kotlin.** 是其中最致命的一条：扩展 dex 不打包 Kotlin 运行时，构造函数里第一条
# 指令往往就是 invoke-static kotlin.LazyKt.lazy / kotlin.jvm.internal.Intrinsics，
# 宿主把 kotlin.Lazy 改名成 W4.f 后，**所有** Kotlin 扩展 100% LOAD_FAILED。
-keep class kotlin.** { public protected *; }
-keep class kotlin.time.** { public protected *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class com.squareup.zstd.** { public protected *; }
-keep class org.jsoup.** { *; }
-keep class rx.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class app.cash.quickjs.** { public protected *; }
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
