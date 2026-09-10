package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.network.HttpException
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
}
