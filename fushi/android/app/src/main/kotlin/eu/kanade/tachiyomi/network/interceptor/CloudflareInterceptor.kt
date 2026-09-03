package eu.kanade.tachiyomi.network.interceptor

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Solves Cloudflare's "Just a moment…" interstitial the only way a headless
 * HTTP client can: by loading the challenged URL in a real [WebView] with the
 * **same** User-Agent the OkHttp client uses, letting Cloudflare's JavaScript
 * run, and waiting for the `cf_clearance` cookie to appear.
 *
 * The cookie lands in Android's shared [CookieManager], which is exactly what
 * [eu.kanade.tachiyomi.network.AndroidCookieJar] reads, so the retried OkHttp
 * request carries the clearance automatically — no cookie copying, and nothing
 * leaves Android's private WebView store.
 *
 * UA parity is essential: Cloudflare binds `cf_clearance` to the User-Agent
 * that solved the challenge. The host sets both the OkHttp UA and the WebView
 * UA from the same provider, so a solved clearance keeps validating.
 */
class CloudflareInterceptor(
    private val context: Context,
    private val userAgentProvider: () -> String,
) : Interceptor {

    private val mainHandler = Handler(Looper.getMainLooper())

    // Serializes only the WebView solve, never ordinary requests: concurrent
    // non-challenged calls must not queue behind each other.
    private val solveLock = Any()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (!response.isCloudflareChallenge()) {
            return response
        }
        // Drain the challenge body before opening the WebView so the socket is
        // released; we only need the retried response.
        response.close()

        try {
            // One WebView solve at a time; a second challenged request waits for
            // the first to seed cf_clearance, then its own retry likely passes.
            synchronized(solveLock) {
                if (!hasClearance(CookieManager.getInstance(), "${request.url.scheme}://${request.url.host}")) {
                    resolveWithWebView(request.url)
                }
            }
        } catch (error: CloudflareBypassException) {
            throw IOException(
                "Cloudflare challenge could not be solved for ${request.url.host}",
                error,
            )
        }

        // Cookies (cf_clearance) now live in the shared CookieManager; retry.
        return chain.proceed(request)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun resolveWithWebView(url: HttpUrl) {
        val latch = CountDownLatch(1)
        val target = url.toString()
        val origin = "${url.scheme}://${url.host}"
        var webView: WebView? = null
        var solved = false

        val cookieManager = CookieManager.getInstance()

        mainHandler.post {
            val view = WebView(context)
            webView = view
            cookieManager.setAcceptThirdPartyCookies(view, true)
            view.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                databaseEnabled = true
                userAgentString = userAgentProvider()
                // Mirror a real browser closely enough for the challenge to run.
                loadsImagesAutomatically = false
                blockNetworkImage = true
            }
            view.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, finishedUrl: String) {
                    // Challenge is cleared once cf_clearance exists for the host.
                    if (hasClearance(cookieManager, origin)) {
                        solved = true
                        latch.countDown()
                    }
                }
            }
            view.loadUrl(target)
        }

        val completed = latch.await(CHALLENGE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        mainHandler.post {
            webView?.stopLoading()
            webView?.destroy()
            webView = null
        }
        cookieManager.flush()

        if (!completed || !solved) {
            throw CloudflareBypassException()
        }
    }

    private fun hasClearance(cookieManager: CookieManager, origin: String): Boolean {
        val cookies = cookieManager.getCookie(origin).orEmpty()
        return cookies.contains("cf_clearance=")
    }

    companion object {
        private const val CHALLENGE_TIMEOUT_SECONDS = 30L
    }
}

/**
 * A Cloudflare interstitial is detected only when Cloudflare explicitly tags
 * the response with `cf-mitigated: challenge` (the header modern challenges
 * always send), on a challenge status code, from a Cloudflare-served response.
 *
 * The header is required on purpose: a bare `Server: cloudflare` 403/503 is
 * ambiguous — many sources sit behind Cloudflare's CDN and legitimately return
 * 403 (hotlink protection) or 503 (origin down). Triggering a 30s WebView solve
 * on those would add latency and break otherwise-working sources, so the
 * conservative `cf-mitigated` signal is the trigger rather than the status
 * alone.
 */
private fun Response.isCloudflareChallenge(): Boolean {
    if (code !in CLOUDFLARE_CHALLENGE_CODES) return false
    val servedByCloudflare = header("Server")
        ?.startsWith("cloudflare", ignoreCase = true) == true
    if (!servedByCloudflare) return false
    return header("cf-mitigated")?.equals("challenge", ignoreCase = true) == true
}

private val CLOUDFLARE_CHALLENGE_CODES = setOf(403, 429, 503)

private class CloudflareBypassException : Exception()
