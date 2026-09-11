package eu.kanade.tachiyomi.network.interceptor

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Upstream shipped this as a pass-through: a headless JVM has no browser to solve a
 * challenge in, so a Cloudflare interstitial simply came back to the extension as a
 * 403/503 HTML page and every source behind Cloudflare read as "broken". The host does
 * have a browser (the desktop WebView login page), so the sidecar's job is only to
 * recognise the interstitial and report it with what the browser needs: the blocked URL
 * and the exact User-Agent the request went out with -- `cf_clearance` is bound to it.
 *
 * Detection mirrors the Android host's interceptor byte for byte, on purpose: the two
 * runtimes must agree on what counts as a challenge or the same source behaves
 * differently per platform.
 */
class CloudflareInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (!response.isCloudflareChallenge()) return response
        response.close()
        throw CloudflareChallengeRequiredException(
            response.request.url,
            response.request.header("User-Agent").orEmpty(),
        )
    }
}

/**
 * A Cloudflare interstitial is detected only when Cloudflare explicitly tags the
 * response with `cf-mitigated: challenge` on a challenge status code from a
 * Cloudflare-served response.
 *
 * The header is required on purpose: a bare `Server: cloudflare` 403/503 is ambiguous --
 * many sources sit behind Cloudflare's CDN and legitimately return 403 (hotlink
 * protection) or 503 (origin down). Sending the user to a WebView for those would add
 * latency and break otherwise-working sources, so the conservative signal is the trigger
 * rather than the status alone.
 */
internal fun Response.isCloudflareChallenge(): Boolean {
    if (code !in CLOUDFLARE_CHALLENGE_CODES) return false
    val servedByCloudflare = header("Server")?.startsWith("cloudflare", ignoreCase = true) == true
    if (!servedByCloudflare) return false
    return header("cf-mitigated")?.equals("challenge", ignoreCase = true) == true
}

private val CLOUDFLARE_CHALLENGE_CODES = setOf(403, 429, 503)

/** Surfaces through DalvikHandler as `errorKind: "cloudflare"` with [url] and [userAgent]. */
class CloudflareChallengeRequiredException(
    val url: HttpUrl,
    val userAgent: String,
) : IOException("CLOUDFLARE_CHALLENGE_REQUIRED: Open website verification")
