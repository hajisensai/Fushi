package eu.kanade.tachiyomi.network.interceptor

import android.content.Context
import okhttp3.Interceptor
import okhttp3.Response

/** Challenges require a user-triggered foreground verification activity. */
@Suppress("UNUSED_PARAMETER")
class CloudflareInterceptor(context: Context, private val userAgentProvider: () -> String) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (!response.isCloudflareChallenge()) return response
        response.close()
        throw CloudflareChallengeRequiredException(response.request.url, response.request.header("User-Agent") ?: userAgentProvider())
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


class CloudflareChallengeRequiredException(val url: okhttp3.HttpUrl, val userAgent: String) : java.io.IOException("CLOUDFLARE_CHALLENGE_REQUIRED: Open website verification")
