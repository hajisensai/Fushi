package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import okhttp3.Cookie
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins the `X-Fushi-Set-Cookie` wire shape (BUG-2425).
 *
 * The literal below is duplicated in the host's
 * `fushi/test/media/manga/mihon_cookie_jar_test.dart`. That duplication is the
 * point: each side has its own encoder/decoder, and a shape change that keeps
 * one side self-consistent still passes that side's own tests while the pair
 * stops working. Pinning one payload in both suites is the only assertion that
 * fails when they drift.
 */
class SourceCookieInjectionTest {
    private val mapper = jacksonObjectMapper()

    private fun persistentCookie() =
        Cookie
            .Builder()
            .name("session")
            .value("abc")
            .domain("bookwalker.jp")
            .path("/")
            .secure()
            .expiresAt(1789000000000L)
            .build()

    private fun sessionCookie() =
        Cookie
            .Builder()
            .name("csrf")
            // Semicolon and comma survive only because the payload is base64'd;
            // a raw JSON header value would be cut here by header parsing.
            .value("x;y,z")
            .domain("bookwalker.jp")
            .path("/")
            .build()

    @Test
    fun `wire payload matches the shape the host decodes`() {
        val encoded =
            SourceCookieInjection.encodeCookies(
                mapper,
                listOf(persistentCookie(), sessionCookie()),
            )

        assertEquals(
            "W3sibmFtZSI6InNlc3Npb24iLCJ2YWx1ZSI6ImFiYyIsImRvbWFpbiI6ImJvb2t3YWxrZXIuanAiLCJwYXRoIjoiLyIsInNl" +
                "Y3VyZSI6dHJ1ZSwiZXhwaXJlc0F0IjoxNzg5MDAwMDAwMDAwfSx7Im5hbWUiOiJjc3JmIiwidmFsdWUiOiJ4O3kseiIsImRv" +
                "bWFpbiI6ImJvb2t3YWxrZXIuanAiLCJwYXRoIjoiLyIsInNlY3VyZSI6ZmFsc2V9XQ==",
            encoded,
        )
    }

    @Test
    fun `session cookies do not carry OkHttp's sentinel expiry`() {
        val encoded = SourceCookieInjection.encodeCookies(mapper, listOf(sessionCookie()))!!
        val json =
            String(
                java.util.Base64
                    .getDecoder()
                    .decode(encoded),
                Charsets.UTF_8,
            )

        // Forwarding the sentinel would turn a session cookie into one that
        // outlives the session the site intended it for.
        assertEquals(false, json.contains("expiresAt"))
    }

    @Test
    fun `no cookies means no header at all`() {
        assertNull(SourceCookieInjection.encodeCookies(mapper, emptyList()))
    }

    @Test
    fun `domainOf falls back to localhost for sources without a base url`() {
        assertEquals("localhost", SourceCookieInjection.domainOf(null))
        assertEquals("localhost", SourceCookieInjection.domainOf("not a source"))
    }
}
