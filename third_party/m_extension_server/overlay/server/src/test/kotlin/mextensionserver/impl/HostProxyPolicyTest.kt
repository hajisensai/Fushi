package mextensionserver.impl

import com.sun.net.httpserver.HttpServer
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails

class HostProxyPolicyTest {
    @Test
    fun globallyInstalledPolicyDoesNotReapplyHttpRoutingToTcpSockets() {
        val previous = ProxySelector.getDefault()
        try {
            ProxySelector.setDefault(HostProxyPolicy)
            ServerSocket(0).use { server ->
                server.soTimeout = 3000
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", server.localPort), 3000)
                    server.accept().use { accepted ->
                        socket.getOutputStream().write(42)
                        accepted.soTimeout = 3000
                        assertEquals(42, accepted.getInputStream().read())
                    }
                }
            }
        } finally {
            ProxySelector.setDefault(previous)
        }
    }

    @Test
    fun globallyInstalledPolicyPreservesSelectedHttpProxyTransport() {
        val previous = ProxySelector.getDefault()
        val proxy = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var requestedUri: String? = null
        proxy.createContext("/") { exchange ->
            requestedUri = exchange.requestURI.toString()
            exchange.sendResponseHeaders(200, -1)
            exchange.close()
        }
        proxy.start()
        val client =
            HostProxyPolicy
                .configureClient(OkHttpClient.Builder())
                .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxy.address.port)))
                .callTimeout(java.time.Duration.ofSeconds(3))
                .build()
        try {
            ProxySelector.setDefault(HostProxyPolicy)
            client.newCall(Request.Builder().url("http://source.invalid/chapter").build()).execute().use {
                assertEquals(200, it.code)
            }
            assertEquals("http://source.invalid/chapter", requestedUri)
        } finally {
            ProxySelector.setDefault(previous)
            proxy.stop(0)
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun proxyAuthenticationDoesNotLeakAcrossRedirectToDirectOrigin() {
        val origin = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val proxy = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var originAuthorization: String? = "not requested"
        origin.createContext("/") { exchange ->
            originAuthorization = exchange.requestHeaders.getFirst("Proxy-Authorization")
            exchange.sendResponseHeaders(200, -1)
            exchange.close()
        }
        proxy.createContext("/") { exchange ->
            if (exchange.requestHeaders.getFirst("Proxy-Authorization") == null) {
                exchange.responseHeaders.add("Proxy-Authenticate", "Basic realm=fixture")
                exchange.sendResponseHeaders(407, -1)
            } else {
                exchange.responseHeaders.add("Location", "http://127.0.0.1:${origin.address.port}/")
                exchange.sendResponseHeaders(302, -1)
            }
            exchange.close()
        }
        origin.start()
        proxy.start()
        val selector =
            object : ProxySelector() {
                override fun select(uri: URI) =
                    if (uri.host == "127.0.0.1") {
                        listOf(Proxy.NO_PROXY)
                    } else {
                        listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxy.address.port)))
                    }

                override fun connectFailed(
                    uri: URI,
                    sa: SocketAddress,
                    ioe: IOException,
                ) = Unit
            }
        val client =
            HostProxyPolicy
                .configureClient(OkHttpClient.Builder(), selector)
                .proxyAuthenticator(
                    HostProxyPolicy.authenticatorFor {
                        HostProxyPolicy.Policy("PROXY 127.0.0.1:${proxy.address.port}", "alice", "secret")
                    },
                ).build()
        try {
            client.newCall(Request.Builder().url("http://source.invalid/").build()).execute().use {
                assertEquals(200, it.code)
            }
            assertEquals(null, originAuthorization)
        } finally {
            origin.stop(0)
            proxy.stop(0)
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun newRequestsFollowChangedPolicyWhilePreviousResponseIsActive() {
        val first = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val second = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        first.createContext("/") { exchange ->
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.write("first".toByteArray())
            exchange.responseBody.flush()
            // Leave the response active while the second request changes route.
        }
        second.createContext("/") { exchange ->
            exchange.sendResponseHeaders(200, 6)
            exchange.responseBody.use { it.write("second".toByteArray()) }
        }
        first.start()
        second.start()
        var selectedPort = first.address.port
        val selections = AtomicInteger()
        val selector =
            object : ProxySelector() {
                override fun select(uri: URI): List<Proxy> {
                    selections.incrementAndGet()
                    return listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", selectedPort)))
                }

                override fun connectFailed(
                    uri: URI,
                    sa: SocketAddress,
                    ioe: IOException,
                ) = Unit
            }
        val client = HostProxyPolicy.configureClient(OkHttpClient.Builder(), selector).build()
        try {
            val request = Request.Builder().url("http://source.invalid/chapter").build()
            client.newCall(request).execute().use { active ->
                assertEquals(200, active.code)
                selectedPort = second.address.port
                client.newCall(request).execute().use { assertEquals("second", it.body.string()) }
            }
            client.newCall(Request.Builder().url("http://source.invalid/next").build()).execute().use {
                assertEquals("second", it.body.string())
            }
            assertEquals(3, selections.get())
        } finally {
            first.stop(0)
            second.stop(0)
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun basicProxyCredentialsAreSentOnlyOnceToMatchingProxy() {
        val proxy = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val attempts = AtomicInteger()
        proxy.createContext("/") { exchange ->
            attempts.incrementAndGet()
            exchange.responseHeaders.add("Proxy-Authenticate", "Basic realm=fixture")
            exchange.sendResponseHeaders(407, -1)
            exchange.close()
        }
        proxy.start()
        val client =
            HostProxyPolicy
                .configureClient(OkHttpClient.Builder())
                .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxy.address.port)))
                .proxyAuthenticator(
                    HostProxyPolicy.authenticatorFor {
                        HostProxyPolicy.Policy("PROXY 127.0.0.1:${proxy.address.port}", "alice", "wrong")
                    },
                ).build()
        try {
            client.newCall(Request.Builder().url("http://source.invalid/").build()).execute().use {
                assertEquals(407, it.code)
            }
            assertEquals(2, attempts.get())
            val mismatch =
                client
                    .newBuilder()
                    .proxyAuthenticator(
                        HostProxyPolicy.authenticatorFor {
                            HostProxyPolicy.Policy("PROXY another.invalid:7890", "alice", "secret")
                        },
                    ).build()
            mismatch.newCall(Request.Builder().url("http://source.invalid/").build()).execute().close()
            assertEquals(3, attempts.get())
        } finally {
            proxy.stop(0)
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun preservesOrderedProxyAndDirectDecisions() {
        val routes = HostProxyPolicy.proxies("PROXY localhost:7890; PROXY [::1]:8080; DIRECT")
        assertEquals(3, routes.size)
        assertEquals(Proxy.Type.HTTP, routes[0].type())
        assertEquals(7890, (routes[0].address() as InetSocketAddress).port)
        assertEquals(8080, (routes[1].address() as InetSocketAddress).port)
        assertEquals(Proxy.NO_PROXY, routes[2])
    }

    @Test
    fun standalonePolicylessSidecarRoutesDirect() {
        val routes =
            HostProxyPolicy.selectWith(URI("https://source.invalid/chapter"), false) {
                error("the host must not be asked when it never supplied an endpoint")
            }
        assertEquals(listOf(Proxy.NO_PROXY), routes)
    }

    @Test
    fun unreachableHostPolicyYieldsAnUnresolvableRouteInsteadOfThrowing() {
        val routes =
            HostProxyPolicy.selectWith(URI("https://source.invalid/chapter"), true) {
                throw IOException("Host proxy policy is unavailable (HTTP 503)")
            }
        // Failing closed: never DIRECT (that would leak past the user's proxy), and never a
        // throw (OkHttp turns a throwing selector into an unbounded retry that exhausts the heap).
        assertEquals(1, routes.size)
        assertEquals(Proxy.Type.HTTP, routes[0].type())
        val address = routes[0].address() as InetSocketAddress
        assertEquals(true, address.isUnresolved)
        assertEquals(false, address.hostString.equals("source.invalid", ignoreCase = true))
    }

    @Test
    fun policyOutageFailsOneCallAndLeavesTheClientUsable() {
        val origin = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        origin.createContext("/") { exchange ->
            exchange.sendResponseHeaders(200, -1)
            exchange.close()
        }
        origin.start()
        var reachable = false
        val selector =
            object : ProxySelector() {
                override fun select(uri: URI): List<Proxy> =
                    HostProxyPolicy.selectWith(uri, true) {
                        if (reachable) {
                            HostProxyPolicy.Policy("DIRECT")
                        } else {
                            throw IOException("Host proxy policy is unavailable (HTTP 503)")
                        }
                    }

                override fun connectFailed(
                    uri: URI,
                    sa: SocketAddress,
                    ioe: IOException,
                ) = Unit
            }
        val client =
            HostProxyPolicy
                .configureClient(OkHttpClient.Builder(), selector)
                .callTimeout(java.time.Duration.ofSeconds(15))
                .build()
        val url = "http://127.0.0.1:${origin.address.port}/"
        try {
            val started = System.nanoTime()
            assertFails {
                client.newCall(Request.Builder().url(url).build()).execute().close()
            }
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            // The old selector threw out of select(); OkHttp then retried routes without bound
            // and the JVM died of OutOfMemoryError in about two seconds, taking every other
            // source in the sidecar with it. One bounded failure is the whole point.
            assertEquals(true, elapsedMs < 15_000, "policy outage must fail fast, took ${elapsedMs}ms")

            reachable = true
            client.newCall(Request.Builder().url(url).build()).execute().use {
                assertEquals(200, it.code)
            }
        } finally {
            origin.stop(0)
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun proxyChallengeSurvivesAPolicyOutage() {
        val proxy = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        proxy.createContext("/") { exchange ->
            exchange.responseHeaders.add("Proxy-Authenticate", "Basic realm=fixture")
            exchange.sendResponseHeaders(407, -1)
            exchange.close()
        }
        proxy.start()
        val client =
            HostProxyPolicy
                .configureClient(OkHttpClient.Builder())
                .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxy.address.port)))
                .proxyAuthenticator(
                    HostProxyPolicy.authenticatorFor {
                        throw IOException("Host proxy policy is unavailable (HTTP 503)")
                    },
                ).callTimeout(java.time.Duration.ofSeconds(15))
                .build()
        try {
            // No credentials to offer, so the call ends at the proxy's own 407 rather than
            // throwing out of OkHttp's follow-up loop.
            client.newCall(Request.Builder().url("http://source.invalid/").build()).execute().use {
                assertEquals(407, it.code)
            }
        } finally {
            proxy.stop(0)
            client.dispatcher.executorService.shutdownNow()
        }
    }

    @Test
    fun malformedPolicyFailsClosed() {
        assertFails { HostProxyPolicy.proxies("") }
        assertFails { HostProxyPolicy.proxies("PROXY user:secret@localhost:7890") }
        assertFails { HostProxyPolicy.proxies("PROXY localhost:0") }
        assertFails { HostProxyPolicy.proxies("SOCKS localhost:1080") }
        assertEquals("Host proxy policy", HostProxyPolicy.Policy("DIRECT", "alice", "secret").toString())
    }
}
