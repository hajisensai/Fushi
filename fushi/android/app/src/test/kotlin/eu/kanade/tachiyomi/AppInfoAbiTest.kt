package eu.kanade.tachiyomi

import java.lang.reflect.Modifier
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BUG-4738：Mihon 扩展把 `eu.kanade.tachiyomi.AppInfo` 当 compileOnly，dex 里写死的是
 * `getstatic AppInfo.INSTANCE` + `invoke-virtual AppInfo.getVersionName()Ljava/lang/String;`
 * 这类按名解析的引用（keiyoushi MangaDex 拼 User-Agent 就这么用）。宿主缺这个类或签名
 * 不对，扩展一加载 / 一发请求就 `NoClassDefFoundError` / `NoSuchMethodError`。
 *
 * 所以这里**只按名字反射**，与扩展 dex 的解析方式一致，而不是直接调 Kotlin API
 * （直接调用在类缺失时连测试都编不过，证明不了 ABI 形状）。
 */
class AppInfoAbiTest {
    private val appInfo: Class<*> = Class.forName("eu.kanade.tachiyomi.AppInfo")

    private fun instance(): Any {
        val field = appInfo.getField("INSTANCE")
        assertTrue(Modifier.isStatic(field.modifiers), "AppInfo.INSTANCE 必须是 static（Kotlin object）")
        return field.get(null)!!
    }

    @Test
    fun versionCodeMatchesExtensionLib13Descriptor() {
        val method = appInfo.getMethod("getVersionCode")
        assertEquals(Int::class.javaPrimitiveType, method.returnType)
        assertEquals(BuildConfigVersion.code, method.invoke(instance()))
    }

    @Test
    fun versionNameMatchesExtensionLib13Descriptor() {
        val method = appInfo.getMethod("getVersionName")
        assertEquals(String::class.java, method.returnType)
        assertEquals(BuildConfigVersion.name, method.invoke(instance()))
    }

    @Test
    fun supportedImageMimeTypesMatchesExtensionLib15Descriptor() {
        val method = appInfo.getMethod("getSupportedImageMimeTypes")
        assertEquals(java.util.List::class.java, method.returnType)
        val types = method.invoke(instance()) as List<*>
        assertTrue(types.isNotEmpty(), "宿主至少要声明一种能显示的页面格式")
        assertTrue(types.all { it is String && it.startsWith("image/") }, "必须是 image/* MIME：$types")
        assertTrue("image/jpeg" in types && "image/png" in types && "image/webp" in types, "$types")
    }

    private object BuildConfigVersion {
        val code: Int get() = app.fushi.reader.BuildConfig.VERSION_CODE
        val name: String get() = app.fushi.reader.BuildConfig.VERSION_NAME
    }
}
