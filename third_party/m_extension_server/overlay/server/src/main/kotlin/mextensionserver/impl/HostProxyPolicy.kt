package mextensionserver.impl

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
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

    private val mapper = jacksonObjectMapper()
    private val port = System.getenv("FUSHI_MIHON_PROXY_POLICY_PORT")?.toIntOrNull()
    private val token = System.getenv("FUSHI_MIHON_TOKEN").orEmpty()

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
        if (port == null || port !in 1..65535 || token.isEmpty()) return false
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
            if (connection.responseCode != 200) throw IOException("Host proxy policy is unavailable")
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

    override fun select(uri: URI): List<Proxy> = proxies(lookup(uri).directive)

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
                val policy = policyLookup(response.request.url.toUri())
                val address = route.proxy.address() as? InetSocketAddress
                val matches =
                    address != null &&
                        proxies(policy.directive).any { candidate ->
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
