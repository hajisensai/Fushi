@file:Suppress("ktlint:standard:function-naming")

package eu.kanade.tachiyomi.network

import okhttp3.CacheControl
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import java.util.concurrent.TimeUnit.MINUTES

private val DEFAULT_CACHE_CONTROL = CacheControl.Builder().maxAge(10, MINUTES).build()
private val DEFAULT_HEADERS = Headers.Builder().build()
private val DEFAULT_BODY: RequestBody = FormBody.Builder().build()

fun GET(
    url: String,
    headers: Headers = DEFAULT_HEADERS,
    cache: CacheControl = DEFAULT_CACHE_CONTROL,
): Request =
    Request
        .Builder()
        .url(url)
        .headers(headers)
        .cacheControl(cache)
        .build()

/**
 * @since extensions-lib 1.4
 */
fun GET(
    url: HttpUrl,
    headers: Headers = DEFAULT_HEADERS,
    cache: CacheControl = DEFAULT_CACHE_CONTROL,
): Request =
    Request
        .Builder()
        .url(url)
        .headers(headers)
        .cacheControl(cache)
        .build()

fun POST(
    url: String,
    headers: Headers = DEFAULT_HEADERS,
    body: RequestBody = DEFAULT_BODY,
    cache: CacheControl = DEFAULT_CACHE_CONTROL,
): Request =
    Request
        .Builder()
        .url(url)
        .post(body)
        .headers(headers)
        .cacheControl(cache)
        .build()

/**
 * Suspending client helpers.
 *
 * Extensions built against the current extensions-lib (yuzono / Anikku lib 16
 * era) call `client.get(url, headers, cache)` directly instead of
 * `client.newCall(GET(url)).awaitSuccess()`. They link against the synthetic
 * `RequestsKt.get$default(OkHttpClient, String, Headers, CacheControl,
 * Continuation, int, Object)`; without these declarations the sidecar answers
 * with a NoSuchMethodError wrapped as BRIDGE_HTTP_500 (measured: AnimeKai's
 * episode list, 2026-09-19). Same shape as kodjodevf/M-Extension-Server
 * v1.0.7 so the wire ABI stays byte-compatible with Mangayomi's sidecar.
 *
 * @since extensions-lib 16
 */
suspend fun OkHttpClient.get(
    url: String,
    headers: Headers = DEFAULT_HEADERS,
    cache: CacheControl = DEFAULT_CACHE_CONTROL,
): Response = newCall(GET(url, headers, cache)).awaitSuccess()

suspend fun OkHttpClient.get(
    url: HttpUrl,
    headers: Headers = DEFAULT_HEADERS,
    cache: CacheControl = DEFAULT_CACHE_CONTROL,
): Response = newCall(GET(url, headers, cache)).awaitSuccess()

suspend fun OkHttpClient.post(
    url: String,
    headers: Headers = DEFAULT_HEADERS,
    body: RequestBody = DEFAULT_BODY,
    cache: CacheControl = DEFAULT_CACHE_CONTROL,
): Response = newCall(POST(url, headers, body, cache)).awaitSuccess()
