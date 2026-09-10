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
 * Response header carrying the cookies a call left in the source's jar
 * (BUG-2425).
 *
 * Payload is base64(UTF-8 JSON array). Base64 is not decoration: cookie values
 * may legitimately contain non-ASCII bytes, commas and semicolons, all of which
 * a raw JSON header value would lose to header parsing on either side, and lose
 * *silently*.
 */
const val SET_COOKIE_HEADER = "X-Fushi-Set-Cookie"

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
 * re-injects it per call; this object is the only place that translates
 * between the two representations.
 *
 * ## Why it is one object and not a copy per handler
 *
 * Both the bridge (`/dalvik`) and image (`/source-image`) paths need the same
 * injection, and the domain rule they use has to match the host's byte for
 * byte — the host picks which cookies to send by that same `baseUrl` host. Two
 * copies of this rule is exactly how the two paths drift until covers load
 * signed-in but pages do not, or the reverse.
 */
object SourceCookieInjection {
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
     * Parses the request's `Cookie:` header into the source's jar.
     *
     * Every cookie is re-scoped to [domain] because that is the only domain the
     * host can address: the host sends one flat `Cookie:` header, which carries
     * no domain of its own. The host performs the matching re-scope when it
     * exports from the browser, so both sides agree on scope.
     */
    fun injectRequestCookies(
        session: NanoHTTPD.IHTTPSession,
        source: Any?,
        domain: String,
    ) {
        val header = session.headers["cookie"] ?: session.headers["Cookie"] ?: return
        val host = domain.removePrefix(".")
        val cookies =
            header
                .split(";")
                .mapNotNull { cookieString ->
                    val parts = cookieString.trim().split("=", limit = 2)
                    val name = parts[0].trim()
                    if (name.isEmpty()) {
                        null
                    } else {
                        Cookie
                            .Builder()
                            .name(name)
                            .value(parts.getOrElse(1) { "" }.trim())
                            .domain(host)
                            .path("/")
                            .build()
                    }
                }.distinctBy { it.name }
        if (cookies.isEmpty()) return
        networkOf(source)?.cookieJar?.addAll(
            HttpUrl.Builder().scheme("http").host(host).build(),
            cookies,
        )
    }

    /** Applies a caller-supplied `User-Agent:` to the source's client. */
    fun applyRequestUserAgent(
        session: NanoHTTPD.IHTTPSession,
        source: Any?,
    ) {
        (session.headers["user-agent"] ?: session.headers["User-Agent"])
            ?.let { userAgent -> networkOf(source)?.setUA(userAgent) }
    }

    /**
     * Serializes the source jar's cookies for [domain] into [SET_COOKIE_HEADER].
     *
     * Reads through `loadForRequest` rather than the jar's internal set so the
     * jar's own domain matching and expiry pruning decide what is in scope —
     * duplicating those rules here is how the two sides drift apart.
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
        val url =
            HttpUrl
                .Builder()
                .scheme("https")
                .host(domain.removePrefix("."))
                .build()
        val cookies = jar.loadForRequest(url)
        if (cookies.isEmpty()) return null
        val payload =
            cookies.map { cookie ->
                buildMap<String, Any?> {
                    put("name", cookie.name)
                    put("value", cookie.value)
                    put("domain", cookie.domain)
                    put("path", cookie.path)
                    put("secure", cookie.secure)
                    // Session cookies carry a sentinel far-future expiry in
                    // OkHttp; forwarding it would turn them into cookies that
                    // outlive the session the site intended them for.
                    if (cookie.persistent) put("expiresAt", cookie.expiresAt)
                }
            }
        return Base64.getEncoder().encodeToString(mapper.writeValueAsBytes(payload))
    }
}
