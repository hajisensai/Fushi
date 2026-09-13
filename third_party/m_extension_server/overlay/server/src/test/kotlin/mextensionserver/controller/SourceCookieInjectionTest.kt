package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import okhttp3.Cookie
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins the host <-> sidecar cookie wire (BUG-2425).
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

    private val wire =
        "W3sibmFtZSI6InNlc3Npb24iLCJ2YWx1ZSI6ImFiYyIsImRvbWFpbiI6Im1lbWJlci5ib29rd2Fsa2VyLmpwIiwicGF0aCI6" +
            "Ii8iLCJzZWN1cmUiOnRydWUsImhvc3RPbmx5Ijp0cnVlLCJleHBpcmVzQXQiOjE3ODkwMDAwMDAwMDB9LHsibmFtZSI6ImNz" +
            "cmYiLCJ2YWx1ZSI6Ing7eSx6IiwiZG9tYWluIjoiYm9va3dhbGtlci5qcCIsInBhdGgiOiIvIiwic2VjdXJlIjpmYWxzZX1d"

    /** host-only + secure + persistent: the three attributes a flat header loses. */
    private fun loginCookie() =
        Cookie
            .Builder()
            .name("session")
            .value("abc")
            .hostOnlyDomain("member.bookwalker.jp")
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
        assertEquals(wire, SourceCookieInjection.encodeCookies(mapper, listOf(loginCookie(), sessionCookie())))
    }

    @Test
    fun `decoding the host's payload restores every attribute`() {
        val decoded = SourceCookieInjection.decodeCookies(wire)

        assertEquals(2, decoded.size)
        val login = decoded[0]
        assertEquals("session", login.name)
        assertEquals("abc", login.value)
        assertEquals("member.bookwalker.jp", login.domain)
        // hostOnly and secure are folded into cookie identity by OkHttp's jar.
        // Losing them is what makes an injected cookie coexist with the site's
        // own instead of replacing it.
        assertTrue(login.hostOnly)
        assertTrue(login.secure)
        assertTrue(login.persistent)
        assertEquals(1789000000000L, login.expiresAt)

        val csrf = decoded[1]
        assertEquals("x;y,z", csrf.value)
        assertEquals("bookwalker.jp", csrf.domain)
        assertTrue(!csrf.hostOnly)
        assertTrue(!csrf.secure)
        // No expiry on the wire means a session cookie, not one that never expires.
        assertTrue(!csrf.persistent)
    }

    @Test
    fun `encode then decode is lossless`() {
        val original = listOf(loginCookie(), sessionCookie())
        val roundTripped =
            SourceCookieInjection.decodeCookies(
                SourceCookieInjection.encodeCookies(mapper, original)!!,
            )
        assertEquals(
            original.map { "${it.name}|${it.domain}|${it.path}|${it.secure}|${it.hostOnly}|${it.persistent}" },
            roundTripped.map { "${it.name}|${it.domain}|${it.path}|${it.secure}|${it.hostOnly}|${it.persistent}" },
        )
    }

    @Test
    fun `session cookies do not carry OkHttp's sentinel expiry`() {
        val encoded = SourceCookieInjection.encodeCookies(mapper, listOf(sessionCookie()))!!
        val json = String(java.util.Base64.getDecoder().decode(encoded), Charsets.UTF_8)

        // Forwarding the sentinel would turn a session cookie into one that
        // outlives the session the site intended it for.
        assertEquals(false, json.contains("expiresAt"))
    }

    @Test
    fun `no cookies means no header at all`() {
        assertNull(SourceCookieInjection.encodeCookies(mapper, emptyList()))
    }

    @Test
    fun `a malformed payload decodes to nothing instead of failing the call`() {
        assertEquals(emptyList(), SourceCookieInjection.decodeCookies("not-base64!!"))
        assertEquals(
            emptyList(),
            SourceCookieInjection.decodeCookies(
                java.util.Base64.getEncoder().encodeToString("{}".toByteArray()),
            ),
        )
    }

    @Test
    fun `entries without a name or domain are dropped`() {
        val payload =
            java.util.Base64
                .getEncoder()
                .encodeToString(
                    """[{"name":"","value":"x","domain":"a.test"},{"name":"y","value":"1","domain":""}]"""
                        .toByteArray(),
                )
        assertEquals(emptyList(), SourceCookieInjection.decodeCookies(payload))
    }

    @Test
    fun `domainOf falls back to localhost for sources without a base url`() {
        assertEquals("localhost", SourceCookieInjection.domainOf(null))
        assertEquals("localhost", SourceCookieInjection.domainOf("not a source"))
    }
}
