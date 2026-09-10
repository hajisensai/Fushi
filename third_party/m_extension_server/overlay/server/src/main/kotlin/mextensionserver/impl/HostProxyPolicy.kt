package mextensionserver.impl

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import io.github.oshai.kotlinlogging.KotlinLogging
import okhttp3.Authenticator
import okhttp3.ConnectionPool
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Protocol
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/** The host owns proxy modes, local bypass and credentials; never duplicate them here. */
object HostProxyPolicy : ProxySelector() {
    private data class CredentialScope(
        val host: String,
        val port: Int,
    )

    private val logger = KotlinLogging.logger {}

    private val mapper = jacksonObjectMapper()
    private val port = System.getenv("FUSHI_MIHON_PROXY_POLICY_PORT")?.toIntOrNull()
    private val token = System.getenv("FUSHI_MIHON_TOKEN").orEmpty()

    /** Single criterion for "the host told us where to ask"; [install] and [select] share it. */
    private val hasHostEndpoint: Boolean
        get() = port != null && port in 1..65535 && token.isNotEmpty()

    /**
     * The route taken when the host owns proxy decisions but cannot be asked right now.
     *
     * `.invalid` never resolves (RFC 2606), so the call fails without reaching the network:
     * a policy outage must not silently downgrade to DIRECT and leak traffic past the user's
     * proxy. It is a returned route rather than a thrown exception because
     * [ProxySelector.select] is not allowed to fail -- see [select].
     */
    private val unavailable =
        listOf(
            Proxy(
                Proxy.Type.HTTP,
                InetSocketAddress.createUnresolved("host-proxy-policy-unavailable.invalid", 1),
            ),
        )

    data class Policy(
        val directive: String,
        val username: String = "",
        val password: String = "",
    ) {
        // Do not let diagnostic interpolation disclose credentials.
        override fun toString() = "Host proxy policy"
    }

    /**
     * Route this JVM's proxy decisions through the host, when the host told us where to ask.
     *
     * Returns false (and installs nothing) when the endpoint is absent: a sidecar started
     * outside Fushi -- the desktop runtime smoke tests in tool/mihon/verify_desktop_runtime.*
     * do exactly this -- has no host to ask, and there is nothing to fall back to but DIRECT.
     * This used to `require(...)`, which threw IllegalArgumentException out of
     * MExtensionServerController.start(); that method only catches IOException, so the process
     * died before printing its ready marker and every desktop build/release job that runs the
     * verify script failed. Refusing to start is not a safer failure mode than starting without
     * a policy -- it just breaks the smoke test.
     *
     * Fushi itself always passes the endpoint, so a false here in production means the host
     * wiring regressed: it is logged, not swallowed silently.
     */
    fun install(): Boolean {
        if (!hasHostEndpoint) return false
        setDefault(this)
        return true
    }

    private fun lookup(uri: URI): Policy {
        val query = URLEncoder.encode(uri.toString(), "UTF-8")
        val connection =
            URI("http://127.0.0.1:$port/proxy-policy?url=$query")
                .toURL()
                .openConnection(Proxy.NO_PROXY) as HttpURLConnection
        try {
            connection.connectTimeout = 3000
            connection.readTimeout = 3000
            connection.setRequestProperty("Authorization", "Bearer $token")
            val status = connection.responseCode
            if (status != 200) throw IOException("Host proxy policy is unavailable (HTTP $status)")
            val json = connection.inputStream.use { mapper.readTree(it) }
            return Policy(json.path("directive").asText(), json.path("username").asText(), json.path("password").asText())
        } finally {
            connection.disconnect()
        }
    }

    internal fun proxies(directive: String): List<Proxy> =
        directive.split(';').map { raw ->
            val part = raw.trim()
            when {
                part.equals("DIRECT", ignoreCase = true) -> Proxy.NO_PROXY
                part.startsWith("PROXY ", ignoreCase = true) -> {
                    val endpoint = URI("http://${part.substring(6).trim()}")
                    require(!endpoint.host.isNullOrBlank() && endpoint.port in 1..65535 && endpoint.rawUserInfo == null)
                    Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(endpoint.host, endpoint.port))
                }
                else -> throw IOException("Unsupported host proxy directive")
            }
        }

    /**
     * Never throws. OkHttp treats a failure here as an unbounded routing retry rather than a
     * failed call: with a throwing selector a single request grows connection state until the
     * JVM dies of OutOfMemoryError in ~2s, killing every source in the sidecar at once, not
     * just the one request. Measured on both shapes this used to produce -- IOException from a
     * non-200 host reply, and URISyntaxException from interpolating a null port into the
     * endpoint URL. So both "no host to ask" and "host cannot answer" are expressed as routes.
     */
    override fun select(uri: URI): List<Proxy> {
        // The JVM also consults its global selector from SocksSocketImpl after
        // the HTTP client has already selected a route. This socket URI names
        // that route's TCP endpoint (possibly the HTTP proxy), not an origin URL.
        // Applying the host's HTTP policy again would reject the socket scheme
        // or proxy the proxy connection. Only this transport lookup is DIRECT;
        // origin HTTP(S) lookups still require a successful host policy response.
        if (uri.scheme.equals("socket", ignoreCase = true)) return listOf(Proxy.NO_PROXY)
        return selectWith(uri, hasHostEndpoint, ::lookup)
    }

    /**
     * @param hostEndpointPresent false when this sidecar runs outside Fushi (the
     *   tool/mihon/verify_desktop_runtime.* smoke tests). There is no host to ask and nothing
     *   to fall back to but DIRECT -- the same reasoning [install] documents for returning false.
     */
    internal fun selectWith(
        uri: URI,
        hostEndpointPresent: Boolean,
        policyLookup: (URI) -> Policy,
    ): List<Proxy> {
        if (!hostEndpointPresent) return listOf(Proxy.NO_PROXY)
        return runCatching { proxies(policyLookup(uri).directive) }
            .getOrElse { failure ->
                logger.warn(failure) { "Host proxy policy unavailable for ${uri.scheme}://${uri.host}; failing closed" }
                unavailable
            }
    }

    override fun connectFailed(
        uri: URI,
        sa: SocketAddress,
        ioe: IOException,
    ) = Unit

    fun configureClient(
        builder: OkHttpClient.Builder,
        selector: ProxySelector = this,
    ): OkHttpClient.Builder =
        builder
            .connectionPool(ConnectionPool(0, 1, TimeUnit.NANOSECONDS))
            .protocols(listOf(Protocol.HTTP_1_1))
            .proxySelector(selector)
            .proxyAuthenticator(authenticator)
            .addNetworkInterceptor { chain ->
                val request = chain.request()
                // A redirect can retain the authenticator's header while changing
                // to a DIRECT route. Never deliver proxy credentials to the origin.
                val proxy = chain.connection()?.route()?.proxy
                val address = proxy?.address() as? InetSocketAddress
                val scope = request.tag(CredentialScope::class.java)
                val credentialRouteMatches =
                    proxy?.type() == Proxy.Type.HTTP &&
                        address != null &&
                        scope != null &&
                        scope.host.equals(address.hostString, ignoreCase = true) &&
                        scope.port == address.port
                val outbound =
                    if (!credentialRouteMatches) {
                        request.newBuilder().removeHeader("Proxy-Authorization").build()
                    } else {
                        request
                    }
                chain.proceed(outbound)
            }

    val authenticator = authenticatorFor(::lookup)

    internal fun authenticatorFor(policyLookup: (URI) -> Policy) =
        Authenticator { route, response ->
            if (route == null ||
                response.code != 407 ||
                response.request.header("Proxy-Authorization") != null ||
                response.challenges().none { it.scheme.equals("Basic", ignoreCase = true) || it.scheme == "OkHttp-Preemptive" }
            ) {
                null
            } else {
                // A policy outage must not propagate out of the authenticator either: OkHttp
                // calls this from inside its follow-up loop, so throwing here has the same
                // unbounded-retry shape select() had. Without credentials the call simply
                // ends at the proxy's 407.
                val policy =
                    runCatching { policyLookup(response.request.url.toUri()) }
                        .getOrElse {
                            logger.warn(it) { "Host proxy policy unavailable while answering a proxy challenge" }
                            null
                        } ?: return@Authenticator null
                val address = route.proxy.address() as? InetSocketAddress
                val matches =
                    address != null &&
                        runCatching { proxies(policy.directive) }.getOrDefault(emptyList()).any { candidate ->
                            val expected = candidate.address() as? InetSocketAddress
                            expected != null &&
                                expected.hostString.equals(address.hostString, ignoreCase = true) &&
                                expected.port == address.port
                        }
                if (!matches || policy.username.isEmpty()) {
                    null
                } else {
                    response.request
                        .newBuilder()
                        .tag(CredentialScope::class.java, CredentialScope(address!!.hostString, address.port))
                        .header("Proxy-Authorization", Credentials.basic(policy.username, policy.password))
                        .build()
                }
            }
        }
}
