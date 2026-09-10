package mextensionserver.controller

import com.fasterxml.jackson.databind.ObjectMapper
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import okhttp3.Cookie
import okhttp3.HttpUrl
import java.util.Base64

/**
 * Request header carrying the cookies the host wants this call to run with
 * (BUG-2425).
 *
 * A dedicated header rather than the standard `Cookie:` one, for two reasons
 * that both surfaced in review after the first attempt used `Cookie:`:
 *
 * 1. A flat `name=value` string drops domain, path, `secure`, `hostOnly` and
 *    expiry. OkHttp's jar folds `secure` and `hostOnly` into cookie *identity*,
 *    so an injected entry missing them coexists with the one the site set
 *    itself, and both go out as `session=stale; session=fresh` — a server
 *    taking the first value gets the dead one.
 * 2. `Cookie:` travels next to `User-Agent:`, and the host's transport sends one
 *    whether it means to or not: `dart:io`'s HttpClient defaults `userAgent` to
 *    `Dart/x.y (dart:io)` and writes it unconditionally. While this class keyed
 *    off the standard `User-Agent:` header, every bridge call rewrote the
 *    source's global UA to that string, so sites that gate on UA kept refusing a
 *    signed-in user.
 *
 * Payload is base64(UTF-8 JSON array) — the same shape as [SET_COOKIE_HEADER],
 * so one codec serves both directions.
 */
const val COOKIE_HEADER = "X-Fushi-Cookies"

/**
 * Response header carrying the cookies a call left in the source's jar.
 *
 * Base64 is not decoration: cookie values may legitimately contain non-ASCII
 * bytes, commas and semicolons, all of which a raw JSON header value would lose
 * to header parsing on either side, and lose *silently*.
 */
const val SET_COOKIE_HEADER = "X-Fushi-Set-Cookie"

/**
 * The source UA the host wants applied, on its own header.
 *
 * Never the transport's `User-Agent:` — see [COOKIE_HEADER] point 2. The host
 * currently never sends this one, which is exactly the intent: the source keeps
 * whatever UA it chose for itself.
 */
const val SOURCE_USER_AGENT_HEADER = "X-Fushi-Source-User-Agent"

/**
 * Moves the login session between the host and a source's OkHttp jar.
 *
 * ## Why the host owns the session
 *
 * This process keeps cookies in a plain in-memory jar, shared by every source
 * and wiped whenever the host restarts the sidecar (which it does on every
 * extension invalidation and source-data clear). A session established here
 * therefore cannot survive, and there is no interactive browser in a headless
 * JVM to establish one in the first place. So the host holds the truth and
 * re-injects it per call; this object is the only place that translates between
 * the two representations.
 *
 * ## Why it is one object and not a copy per handler
 *
 * Both the bridge (`/dalvik`) and image (`/source-image`) paths need the same
 * injection, and the shape they use has to match the host's byte for byte. Two
 * copies of this rule is exactly how the two paths drift until covers load
 * signed-in but pages do not, or the reverse.
 */
object SourceCookieInjection {
    private val jsonMapper = ObjectMapper()

    /** The source's registrable host, or `localhost` when it reports none. */
    fun domainOf(source: Any?): String =
        try {
            val baseUrl = source?.javaClass?.getMethod("getBaseUrl")?.invoke(source) as? String
            baseUrl?.let { java.net.URI(it).host }
        } catch (error: Exception) {
            null
        } ?: "localhost"

    fun networkOf(source: Any?): NetworkHelper? =
        when (source) {
            is HttpSource -> source.network
            is AnimeHttpSource -> source.network
            else -> null
        }

    /**
     * Parses [COOKIE_HEADER] into the source's jar, preserving every attribute.
     *
     * Domains arrive as the browser recorded them, so a session cookie scoped to
     * a login subdomain stays scoped there instead of being widened to the
     * source's registrable domain and all of its subdomains.
     */
    fun injectRequestCookies(
        session: NanoHTTPD.IHTTPSession,
        source: Any?,
    ) {
        val header = headerOf(session, COOKIE_HEADER) ?: return
        val cookies = decodeCookies(header)
        if (cookies.isEmpty()) return
        val jar = networkOf(source)?.cookieJar ?: return
        cookies.forEach { cookie ->
            jar.addAll(
                HttpUrl
                    .Builder()
                    .scheme(if (cookie.secure) "https" else "http")
                    .host(cookie.domain)
                    .build(),
                listOf(cookie),
            )
        }
    }

    /** Applies the host-supplied source UA, if it sent one. */
    fun applyRequestUserAgent(
        session: NanoHTTPD.IHTTPSession,
        source: Any?,
    ) {
        headerOf(session, SOURCE_USER_AGENT_HEADER)
            ?.takeIf { it.isNotBlank() }
            ?.let { userAgent -> networkOf(source)?.setUA(userAgent) }
    }

    /**
     * Serializes the source jar's cookies for [domain] into [SET_COOKIE_HEADER].
     *
     * Reads through `loadForRequest` rather than the jar's internal set so the
     * jar's own domain matching and expiry pruning decide what is in scope —
     * duplicating those rules here is how the two sides drift apart. Both
     * schemes are queried because `secure` cookies match only an https URL, and
     * dropping them would report a signed-in session as signed-out.
     *
     * Returns null when there is nothing to report, so a call that touches no
     * cookies costs no header and no host-side disk write.
     */
    fun encodeJarCookies(
        mapper: ObjectMapper,
        source: Any?,
        domain: String,
    ): String? {
        val jar = networkOf(source)?.cookieJar ?: return null
        val host = domain.removePrefix(".")
        val cookies =
            listOf("https", "http")
                .flatMap { scheme ->
                    jar.loadForRequest(
                        HttpUrl
                            .Builder()
                            .scheme(scheme)
                            .host(host)
                            .build(),
                    )
                }.distinctBy { Triple(it.name, it.domain, it.path) }
        return encodeCookies(mapper, cookies)
    }

    /**
     * The wire shape itself, split out so it can be pinned by a test without a
     * loaded extension.
     *
     * The host decodes this in `mihon_cookie_jar.dart`; the two sides are only
     * verified together by pinning one literal payload in both test suites. A
     * shape change that keeps each side self-consistent is exactly the kind that
     * ships broken, because either side alone still passes.
     */
    fun encodeCookies(
        mapper: ObjectMapper,
        cookies: List<Cookie>,
    ): String? {
        if (cookies.isEmpty()) return null
        val payload =
            cookies.map { cookie ->
                buildMap<String, Any?> {
                    put("name", cookie.name)
                    put("value", cookie.value)
                    put("domain", cookie.domain)
                    put("path", cookie.path)
                    put("secure", cookie.secure)
                    if (cookie.hostOnly) put("hostOnly", true)
                    // Session cookies carry a sentinel far-future expiry in
                    // OkHttp; forwarding it would turn them into cookies that
                    // outlive the session the site intended them for.
                    if (cookie.persistent) put("expiresAt", cookie.expiresAt)
                }
            }
        return Base64.getEncoder().encodeToString(mapper.writeValueAsBytes(payload))
    }

    /** Inverse of [encodeCookies]; a malformed payload means "no cookies". */
    fun decodeCookies(raw: String): List<Cookie> =
        try {
            val decoded = String(Base64.getDecoder().decode(raw), Charsets.UTF_8)
            val nodes = jsonMapper.readTree(decoded)
            if (!nodes.isArray) {
                emptyList()
            } else {
                nodes.mapNotNull { node ->
                    val name = node.path("name").asText("").trim()
                    val domain =
                        node
                            .path("domain")
                            .asText("")
                            .trim()
                            .removePrefix(".")
                    if (name.isEmpty() || domain.isEmpty()) {
                        null
                    } else {
                        Cookie
                            .Builder()
                            .name(name)
                            .value(node.path("value").asText(""))
                            .path(node.path("path").asText("/").ifBlank { "/" })
                            .apply {
                                if (node.path("hostOnly").asBoolean(false)) {
                                    hostOnlyDomain(domain)
                                } else {
                                    domain(domain)
                                }
                                if (node.path("secure").asBoolean(false)) secure()
                                val expiresAt = node.path("expiresAt")
                                if (expiresAt.isNumber) expiresAt(expiresAt.asLong())
                            }.build()
                    }
                }
            }
        } catch (error: IllegalArgumentException) {
            // Not base64, or a domain OkHttp refuses. Either way the host's copy
            // stays authoritative and the next call sends it again; failing the
            // whole source invocation over a header would be far worse.
            emptyList()
        } catch (error: com.fasterxml.jackson.core.JacksonException) {
            emptyList()
        }

    /** NanoHTTPD lowercases header names; be explicit rather than rely on it. */
    private fun headerOf(
        session: NanoHTTPD.IHTTPSession,
        name: String,
    ): String? = session.headers[name.lowercase()] ?: session.headers[name]
}
