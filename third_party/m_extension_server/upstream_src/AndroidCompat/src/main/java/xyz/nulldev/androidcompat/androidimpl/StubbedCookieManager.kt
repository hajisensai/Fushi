package xyz.nulldev.androidcompat.androidimpl

import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebView

class StubbedCookieManager : CookieManager() {
    override fun setAcceptCookie(accept: Boolean) {
        throw NotImplementedError()
    }

    override fun acceptCookie(): Boolean {
        throw NotImplementedError()
    }

    override fun setAcceptThirdPartyCookies(webview: WebView?, accept: Boolean) {
    }

    override fun acceptThirdPartyCookies(webview: WebView?): Boolean {
        throw NotImplementedError()
    }

    override fun setCookie(url: String, value: String) {
    }

    override fun setCookie(url: String?, value: String?, callback: ValueCallback<Boolean>?) {
    }

    override fun getCookie(url: String?): String {
        throw NotImplementedError()
    }

    @Deprecated("Deprecated in Java")
    override fun removeSessionCookie() {
    }

    override fun removeSessionCookies(callback: ValueCallback<Boolean>?) {
    }

    @Deprecated("Deprecated in Java")
    override fun removeAllCookie() {
    }

    override fun removeAllCookies(callback: ValueCallback<Boolean>?) {
    }

    override fun hasCookies(): Boolean {
        throw NotImplementedError()
    }

    @Deprecated("Deprecated in Java")
    override fun removeExpiredCookie() {
    }

    override fun flush() {
    }

    override fun allowFileSchemeCookiesImpl(): Boolean {
        throw NotImplementedError()
    }

    override fun setAcceptFileSchemeCookiesImpl(accept: Boolean) {
    }
}