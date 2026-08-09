package eu.kanade.tachiyomi.network

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Cookie jar compatible with Mihon's extension ABI. Cookies remain in Android's
 * private WebView store and are never copied into Dart, sync, backup, or logs.
 */
class AndroidCookieJar : CookieJar {
    private val manager: CookieManager by lazy { CookieManager.getInstance() }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cookies.forEach { cookie -> manager.setCookie(url.toString(), cookie.toString()) }
        manager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> = get(url)

    fun get(url: HttpUrl): List<Cookie> {
        val value = manager.getCookie(url.toString()).orEmpty()
        return if (value.isEmpty()) {
            emptyList()
        } else {
            value.split(";").mapNotNull { cookie -> Cookie.parse(url, cookie.trim()) }
        }
    }

    fun remove(url: HttpUrl, cookieNames: List<String>? = null, maxAge: Int = -1): Int {
        val names = get(url)
            .map { cookie -> cookie.name }
            .filter { name -> cookieNames == null || name in cookieNames }
        names.forEach { name ->
            manager.setCookie(url.toString(), "$name=; Max-Age=$maxAge; Path=/")
        }
        manager.flush()
        return names.size
    }

    fun removeAll() {
        manager.removeAllCookies(null)
        manager.flush()
    }
}
