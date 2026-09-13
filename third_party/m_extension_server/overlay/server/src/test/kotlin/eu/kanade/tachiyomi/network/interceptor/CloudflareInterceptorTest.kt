package eu.kanade.tachiyomi.network.interceptor

import com.sun.net.httpserver.HttpServer
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetSocketAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class CloudflareInterceptorTest {
    private fun serve(
        status: Int,
        headers: Map<String, String>,
        body: (OkHttpClient, String) -> Unit,
    ) {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            headers.forEach { (name, value) -> exchange.responseHeaders.add(name, value) }
            exchange.sendResponseHeaders(status, -1)
            exchange.close()
        }
        server.start()
        val client =
            OkHttpClient
                .Builder()
                .addInterceptor(UserAgentInterceptor { "Mozilla/5.0 fixture" })
                .addInterceptor(CloudflareInterceptor())
                .build()
        try {
            body(client, "http://127.0.0.1:${server.address.port}/manga/list?page=2")
        } finally {
            server.stop(0)
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun taggedChallengeSurfacesTheBlockedUrlAndTheUserAgentThatWasSent() {
        serve(403, mapOf("Server" to "cloudflare", "cf-mitigated" to "challenge")) { client, url ->
            val challenge =
                assertFailsWith<CloudflareChallengeRequiredException> {
                    client.newCall(Request.Builder().url(url).build()).execute().close()
                }
            assertEquals(url, challenge.url.toString())
            // cf_clearance is issued against this exact string; the browser must reuse it.
            assertEquals("Mozilla/5.0 fixture", challenge.userAgent)
        }
    }

    @Test
    fun aSourceSuppliedUserAgentWinsOverTheDefault() {
        serve(503, mapOf("Server" to "cloudflare", "cf-mitigated" to "challenge")) { client, url ->
            val challenge =
                assertFailsWith<CloudflareChallengeRequiredException> {
                    client
                        .newCall(Request.Builder().url(url).header("User-Agent", "SourceBot/1.0").build())
                        .execute()
                        .close()
                }
            assertEquals("SourceBot/1.0", challenge.userAgent)
        }
    }

    @Test
    fun untaggedCloudflareErrorsPassThroughUnchanged() {
        // Hotlink 403s and origin-down 503s from Cloudflare's CDN are not challenges.
        for (status in listOf(403, 503)) {
            serve(status, mapOf("Server" to "cloudflare")) { client, url ->
                client.newCall(Request.Builder().url(url).build()).execute().use {
                    assertEquals(status, it.code)
                }
            }
        }
    }

    @Test
    fun challengeHeaderWithoutCloudflareServerIsNotAChallenge() {
        serve(403, mapOf("Server" to "nginx", "cf-mitigated" to "challenge")) { client, url ->
            client.newCall(Request.Builder().url(url).build()).execute().use {
                assertEquals(403, it.code)
            }
        }
    }
}
