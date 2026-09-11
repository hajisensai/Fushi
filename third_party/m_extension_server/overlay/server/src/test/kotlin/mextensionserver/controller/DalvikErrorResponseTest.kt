package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeRequiredException
import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DalvikErrorResponseTest {
    @Test
    fun `source HTTP failures retain status and typed origin across response serialization`() {
        // 599 also exercises statuses missing from NanoHTTPD's fixed enum.
        for (statusCode in listOf(403, 429, 500, 502, 503, 599)) {
            val error = HttpException(statusCode)
            val response = DalvikHandler().errorResponse(error)
            assertEquals(statusCode, response.status.requestStatus)
            val body = response.data.use { jacksonObjectMapper().readTree(it) }
            assertEquals("sourceHttp", body["errorKind"].asText())
            assertTrue(body["sourceStatusCode"].isIntegralNumber)
            assertEquals(statusCode, body["sourceStatusCode"].asInt())
            assertEquals(statusCode, body["code"].asInt())
            assertEquals(error.javaClass.name, body["errorType"].asText())
            assertEquals(error.message, body["error"].asText())
            assertTrue(body["stackTrace"].asText().contains("HttpException"))
        }
    }

    @Test
    fun `internal failures remain bridge failures regardless of HTTP-like message`() {
        for (error in listOf(IllegalStateException("HTTP error 502"), NoSuchMethodError("missing method"))) {
            val response = DalvikHandler().errorResponse(error)
            assertEquals(500, response.status.requestStatus)
            val body = response.data.use { jacksonObjectMapper().readTree(it) }
            assertEquals("bridge", body["errorKind"].asText())
            assertTrue(body["sourceStatusCode"].isNull)
            assertEquals(500, body["code"].asInt())
            assertEquals(error.javaClass.name, body["errorType"].asText())
            assertEquals(error.message, body["error"].asText())
            assertTrue(body["stackTrace"].asText().isNotEmpty())
        }
    }

    @Test
    fun `invalid source HTTP status cannot become a successful bridge response`() {
        for (statusCode in listOf(200, 399, 600)) {
            val response = DalvikHandler().errorResponse(HttpException(statusCode))
            assertEquals(500, response.status.requestStatus)
            val body = response.data.use { jacksonObjectMapper().readTree(it) }
            assertEquals("bridge", body["errorKind"].asText())
            assertTrue(body["sourceStatusCode"].isNull)
        }
    }

    @Test
    fun `a Cloudflare challenge is reported with the URL and User-Agent the browser must reuse`() {
        val challenge =
            CloudflareChallengeRequiredException(
                "https://source.invalid/manga/list?page=2".toHttpUrl(),
                "Mozilla/5.0 fixture",
            )
        // The interceptor's exception arrives wrapped by whichever adapter rethrew it.
        for (error in listOf<Throwable>(challenge, RuntimeException("wrapped", challenge))) {
            val response = DalvikHandler().errorResponse(error)
            val body = response.data.use { jacksonObjectMapper().readTree(it) }
            assertEquals("cloudflare", body["errorKind"].asText())
            assertEquals("https://source.invalid/manga/list?page=2", body["challengeUrl"].asText())
            assertEquals("Mozilla/5.0 fixture", body["userAgent"].asText())
            assertTrue(body["sourceStatusCode"].isNull)
        }
    }

    @Test
    fun `ordinary failures carry no challenge fields`() {
        val body =
            DalvikHandler().errorResponse(HttpException(403)).data.use { jacksonObjectMapper().readTree(it) }
        assertEquals("sourceHttp", body["errorKind"].asText())
        assertTrue(body["challengeUrl"].isNull)
        assertTrue(body["userAgent"].isNull)
    }
}
