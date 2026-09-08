package app.fushi.reader.mihon

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.HttpUrl
import java.io.IOException
import java.lang.ref.WeakReference
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Explicit foreground verification only; extension requests never open activities. */
object CloudflareChallengeCoordinator {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var endpoint: URI? = null
    private var foreground = WeakReference<Activity>(null)
    private var initialized = false
    private val solveLock = Any()
    private val activeSession = AtomicBoolean(false)

    @Synchronized
    fun initialize(app: Application) {
        if (initialized) return
        initialized = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) { foreground = WeakReference(activity) }
            override fun onActivityPaused(activity: Activity) { if (foreground.get() === activity) foreground.clear() }
            override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    fun configure(endpoint: URI) {
        require(endpoint.scheme == "http" && endpoint.host == "127.0.0.1" && endpoint.port in 1..65535 && !endpoint.userInfo.isNullOrEmpty()) {
            "Invalid local challenge proxy"
        }
        this.endpoint = endpoint
    }

    fun solve(context: Context, url: HttpUrl, userAgent: String) = synchronized(solveLock) {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Verification must run off the main thread" }
        val proxy = endpoint ?: throw IOException("Challenge proxy is not configured")
        if (!activeSession.compareAndSet(false, true)) {
            throw MihonHostException("CHALLENGE_CLEANUP_PENDING", "Previous verification is still closing; reopen the app if cleanup does not finish")
        }
        val completed = CountDownLatch(1)
        var failure: String? = "Verification was not completed"
        var cookieText: String? = null
        var resultCode = "CHALLENGE_CANCELLED"
        var cancellation: ResultReceiver? = null
        var cancelled = false
        var staleClearance: String? = null
        val receiver = object : ResultReceiver(main) {
            override fun onReceiveResult(code: Int, data: Bundle?) {
                if (code == Activity.RESULT_FIRST_USER) {
                    cancellation = data?.getParcelable("control")
                    if (cancelled) cancellation?.send(0, null)
                    return
                }
                resultCode = data?.getString("code") ?: "CHALLENGE_CANCELLED"
                activeSession.set(false)
                if (code == Activity.RESULT_OK) {
                    cookieText = data?.getString("cookies")
                    failure = null
                } else failure = if (resultCode == "CHALLENGE_PROXY_UNSUPPORTED") {
                    "Website verification requires Android 9 or newer and a WebView with proxy override support"
                } else "Verification cancelled or unavailable"
                completed.countDown()
            }
        }
        main.post {
            val activity = foreground.get()
            if (activity == null || activity.isFinishing || activity.isDestroyed) {
                activeSession.set(false)
                failure = "Verification requires a foreground activity"
                completed.countDown()
            } else {
                try {
                    val primaryCookies = CookieManager.getInstance().getCookie(url.toString()).orEmpty()
                    staleClearance = primaryCookies.split(';').firstOrNull { it.trim().startsWith("cf_clearance=") }?.trim()
                    activity.startActivity(Intent(context, CloudflareChallengeActivity::class.java)
                        .putExtra("target", url.toString()).putExtra("userAgent", userAgent)
                        .putExtra("proxy", proxy.toString()).putExtra("receiver", receiver)
                        .putExtra("staleClearance", staleClearance))
                } catch (_: Exception) {
                    activeSession.set(false)
                    failure = "Unable to open verification"
                    completed.countDown()
                }
            }
        }
        try {
            if (!completed.await(100, TimeUnit.SECONDS)) {
                main.post { cancelled = true; cancellation?.send(0, null) }
                throw MihonHostException("CHALLENGE_TIMEOUT", "Verification timed out")
            }
        } catch (error: InterruptedException) {
            main.post { cancelled = true; cancellation?.send(0, null) }
            Thread.currentThread().interrupt()
            throw MihonHostException("CHALLENGE_CANCELLED", "Verification cancelled")
        }
        failure?.let { throw MihonHostException(resultCode, it) }
        // getCookie omits HttpOnly/SameSite/path metadata. Never copy primary
        // login cookies into the browser (which would make HttpOnly values JS
        // readable), and never overwrite them on return. Import only clearance.
        val cookies = cookieText.orEmpty().split(';').mapNotNull { Cookie.parse(url, it.trim()) }
            .filter { it.name == "cf_clearance" }
        if (cookies.none { it.name == "cf_clearance" && it.value.isNotEmpty() && "cf_clearance=${it.value}" != staleClearance }) throw IOException("Verification returned no clearance")
        val stored = CountDownLatch(cookies.size)
        var cookieFailure = false
        main.post {
            val manager = CookieManager.getInstance()
            cookies.forEach { cookie ->
                // getCookie omits scope attributes: rebuild host-only cookies for this origin.
                val value = Cookie.Builder().name(cookie.name).value(cookie.value)
                    .hostOnlyDomain(url.host).path("/").httpOnly().apply { if (url.isHttps) secure() }.build()
                manager.setCookie(url.toString(), value.toString()) { accepted ->
                    if (!accepted) cookieFailure = true
                    stored.countDown()
                }
            }
        }
        if (!stored.await(10, TimeUnit.SECONDS) || cookieFailure) throw IOException("Unable to store verification cookies")
    }
}
