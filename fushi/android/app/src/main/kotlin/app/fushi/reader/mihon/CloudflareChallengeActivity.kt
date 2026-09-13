package app.fushi.reader.mihon

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.webkit.CookieManager
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.ByteArrayInputStream
import java.net.URI
import java.net.InetAddress

/** Dedicated process so a challenge proxy never changes reader/browser WebViews. */
class CloudflareChallengeActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private var browser: WebView? = null
    private var receiver: ResultReceiver? = null
    private var finished = false
    private var target: HttpUrl? = null
    private var endpoint: URI? = null
    private val proxyLifecycle = ChallengeProxyLifecycle { done ->
        ProxyController.getInstance().clearProxyOverride({ main.post(it) }) { done() }
    }
    private var authAttempted = false

    /**
     * The two callbacks [complete] is allowed to cancel.
     *
     * They used to be cancelled with `main.removeCallbacksAndMessages(null)`, which wipes the
     * **whole** main queue -- including the `setProxyOverride` completion that calls
     * [ChallengeProxyLifecycle.installed] (its executor posts there too). Cancelling between
     * the post and its run left the lifecycle stuck in `installing`, so `close()` early-returned
     * and the reply was never sent: the coordinator waited out its 100 s timeout, and that path
     * deliberately does not reset `activeSession`, so every later verification returned
     * CHALLENGE_CLEANUP_PENDING until the app was restarted. Every other main-queue callback
     * here already no-ops on [finished]; only these two need explicit cancelling.
     */
    private var timeoutCallback: Runnable? = null
    private var clearancePoll: Runnable? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(state: Bundle?) {
        // The isolated process has not created WebViews or CookieManager yet.
        // Throws if this process already created a WebView. It cannot here (dedicated
        // process, this is the only entry point), but a crash in onCreate would take the
        // whole verification down with no reply, so it degrades instead.
        if (Build.VERSION.SDK_INT >= 28 && !dataDirectoryConfigured) {
            dataDirectoryConfigured = runCatching {
                WebView.setDataDirectorySuffix("network_challenge")
            }.isSuccess
        }
        super.onCreate(state)
        receiver = intent.getParcelableExtra("receiver")
        receiver?.send(RESULT_FIRST_USER, Bundle().apply {
            putParcelable("control", object : ResultReceiver(main) {
                override fun onReceiveResult(code: Int, data: Bundle?) { complete(false) }
            })
        })
        if (Build.VERSION.SDK_INT < 28 || !WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            complete(false, code = "CHALLENGE_PROXY_UNSUPPORTED")
            return
        }
        if (state != null) { complete(false); return }
        val url = intent.getStringExtra("target")?.toHttpUrlOrNull()
        val proxy = runCatching { URI(intent.getStringExtra("proxy").orEmpty()) }.getOrNull()
        if (url == null || isLocalHost(url.host) || proxy?.host != "127.0.0.1" || proxy.scheme != "http" || proxy.port !in 1..65535 || proxy.userInfo.isNullOrBlank()) {
            complete(false, code = "CHALLENGE_UNAVAILABLE")
            return
        }
        target = url
        endpoint = proxy
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.WHITE) }
        layout.addView(Button(this).apply { setText(android.R.string.cancel); setOnClickListener { complete(false) } })
        // No WebView provider (updating / disabled / missing) throws here.
        val view = runCatching { WebView(this) }.getOrNull()
        if (view == null) {
            complete(false, code = "CHALLENGE_UNAVAILABLE")
            return
        }
        browser = view
        layout.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(layout)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = intent.getStringExtra("userAgent").orEmpty()
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        view.webViewClient = object : WebViewClient() {
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                main.post { complete(false, code = "CHALLENGE_UNAVAILABLE") }
                return true
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val next = request.url.toString().toHttpUrlOrNull() ?: return true
                return request.isForMainFrame && !sameOrigin(url, next) || isLocalHost(next.host)
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                val next = request.url.toString().toHttpUrlOrNull()
                val blocked = next == null || isLocalHost(next.host) ||
                    request.isForMainFrame && !sameOrigin(url, next)
                return if (blocked) WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0))) else null
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) main.post { complete(false, code = "CHALLENGE_UNAVAILABLE") }
            }
            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                if (request.isForMainFrame && response.statusCode == 407) main.post { complete(false, code = "CHALLENGE_UNAVAILABLE") }
            }
            override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String) {
                // Local origins and subresources are blocked above. Only the dedicated
                // loopback proxy may challenge with this private realm.
                val credentials = proxy.userInfo.split(':', limit = 2)
                if (!authAttempted && host == proxy.host && realm == "Fushi native" && credentials.size == 2) {
                    authAttempted = true
                    handler.proceed(credentials[0], credentials[1])
                } else handler.cancel()
            }
        }
        val timeout = Runnable { complete(false, code = "CHALLENGE_TIMEOUT") }
        timeoutCallback = timeout
        main.postDelayed(timeout, 90_000)
        val config = ProxyConfig.Builder().addProxyRule("http://127.0.0.1:${proxy.port}").removeImplicitRules().build()
        proxyLifecycle.begin()
        // A throw here would leave the lifecycle stuck in `installing` forever: close()
        // early-returns while installing, so the reply would never be sent and the
        // coordinator's session lease would never be released.
        val installed = runCatching {
        ProxyController.getInstance().setProxyOverride(config, { main.post(it) }) {
            proxyLifecycle.installed()
            if (finished) {
                return@setProxyOverride
            }
            val manager = CookieManager.getInstance()
            manager.setAcceptThirdPartyCookies(view, true)
            // Expire this origin's old clearance before any navigation. A stale
            // cookie can never turn a failed challenge into a successful result.
            val previousClearance = manager.getCookie(url.toString()).orEmpty().split(';')
                .firstOrNull { it.trim().startsWith("cf_clearance=") }?.trim()
            manager.setCookie(url.toString(), "cf_clearance=; Max-Age=0; Path=/") { accepted ->
                if (!accepted) { complete(false, code = "CHALLENGE_UNAVAILABLE"); return@setCookie }
                if (finished) return@setCookie
                // Primary login cookies are deliberately not transferred:
                // CookieManager cannot export their HttpOnly/scope metadata.
                view.loadUrl(url.toString())
                val poll = object : Runnable {
                    override fun run() {
                        if (finished) return
                        val cookies = manager.getCookie(url.toString()).orEmpty()
                        val clearance = cookies.split(';').any { it.trim().startsWith("cf_clearance=") && it.substringAfter('=').isNotEmpty() && it.trim() != previousClearance && it.trim() != intent.getStringExtra("staleClearance") }
                        if (clearance) complete(true, cookies) else main.postDelayed(this, 500)
                    }
                }
                clearancePoll = poll
                main.post(poll)
            }
        }
        }
        if (installed.isFailure) {
            // Nothing was installed, so nothing has to be undone: hand the lifecycle the
            // terminal transition it is waiting for, then report unavailable.
            runCatching { proxyLifecycle.installed() }
            complete(false, code = "CHALLENGE_UNAVAILABLE")
        }
    }

    private fun complete(success: Boolean, cookies: String? = null, code: String = "CHALLENGE_CANCELLED") {
        if (finished) return
        finished = true
        timeoutCallback?.let(main::removeCallbacks)
        timeoutCallback = null
        clearancePoll?.let(main::removeCallbacks)
        clearancePoll = null
        val resultReceiver = receiver
        receiver = null
        val reply: () -> Unit = {
            resultReceiver?.send(if (success) RESULT_OK else RESULT_CANCELED, Bundle().apply { putString("code", code); if (cookies != null) putString("cookies", cookies) })
        }
        browser?.stopLoading()
        browser?.destroy()
        browser = null
        // Close the visible page immediately, but retain the coordinator lease
        // until late proxy setup and cleanup callbacks have both completed.
        proxyLifecycle.close(reply)
        finish()
    }

    @Deprecated("Android callback")
    override fun onBackPressed() { complete(false) }

    override fun onDestroy() {
        complete(false)
        super.onDestroy()
    }

    companion object {
        private var dataDirectoryConfigured = false
        internal fun sameOrigin(first: HttpUrl, second: HttpUrl): Boolean = first.scheme == second.scheme && first.host == second.host && first.port == second.port
        internal fun isLocalHost(host: String): Boolean {
            val value = host.lowercase().removeSuffix(".")
            if (value == "localhost" || value.endsWith(".localhost") || value.endsWith(".local") || value == "::1" || value == "::") return true
            if (value.contains(':')) {
                // HttpUrl has already validated this as an IPv6 literal; this
                // parses bytes only, never resolves a hostname through local DNS.
                val address = runCatching { InetAddress.getByName(value) }.getOrNull() ?: return true
                return address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
                    address.isSiteLocalAddress || address.isMulticastAddress ||
                    (address.address[0].toInt() and 0xfe) == 0xfc
            }
            val parts = value.split('.').mapNotNull(String::toIntOrNull)
            return parts.size == 4 && (parts[0] in listOf(0, 10, 127) || parts[0] == 169 && parts[1] == 254 || parts[0] == 172 && parts[1] in 16..31 || parts[0] == 192 && parts[1] == 168 || parts[0] >= 224)
        }
    }
}
