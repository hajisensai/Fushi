package app.fushi.reader.mihon

import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.net.SocketAddress
import java.io.IOException
import com.sun.net.httpserver.HttpServer
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails

class HostProxyPolicyTest {
    @Test
    fun authenticatedLoopbackLookupReadsUpdatedPolicyForEachUrl() {
        val token = "android-policy-test-token-with-32-bytes"
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var directive = "DIRECT"
        var allow = true
        server.createContext("/proxy-policy") { exchange ->
            assertEquals("Bearer $token", exchange.requestHeaders.getFirst("Authorization"))
            val body = "{\"directive\":\"$directive\"}".toByteArray()
            exchange.sendResponseHeaders(if (allow) 200 else 401, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        try {
            HostProxyPolicy.configure(server.address.port, token)
            assertEquals(listOf(Proxy.NO_PROXY), HostProxyPolicy.select(URI("https://source.invalid/one")))
            directive = "PROXY 127.0.0.1:7890"
            assertEquals(7890, (HostProxyPolicy.select(URI("https://source.invalid/two")).single().address() as InetSocketAddress).port)
            allow = false
            assertFails { HostProxyPolicy.select(URI("https://source.invalid/three")) }
        } finally {
            server.stop(0)
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
        val selector = object : ProxySelector() {
            override fun select(uri: URI) = if (uri.host == "127.0.0.1") listOf(Proxy.NO_PROXY) else
                listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxy.address.port)))
            override fun connectFailed(uri: URI, sa: SocketAddress, ioe: IOException) = Unit
        }
        val client = HostProxyPolicy.configureClient(OkHttpClient.Builder(), selector)
            .proxyAuthenticator(HostProxyPolicy.authenticatorFor {
                HostProxyPolicy.Policy("PROXY 127.0.0.1:${proxy.address.port}", "alice", "secret")
            }).build()
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
        val selector = object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                selections.incrementAndGet()
                return listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", selectedPort)))
            }
            override fun connectFailed(uri: URI, sa: SocketAddress, ioe: IOException) = Unit
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
        val client = HostProxyPolicy.configureClient(OkHttpClient.Builder())
            .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxy.address.port)))
            .proxyAuthenticator(HostProxyPolicy.authenticatorFor {
                HostProxyPolicy.Policy("PROXY 127.0.0.1:${proxy.address.port}", "alice", "wrong")
            }).build()
        try {
            client.newCall(Request.Builder().url("http://source.invalid/").build()).execute().use {
                assertEquals(407, it.code)
            }
            assertEquals(2, attempts.get())
            val mismatch = client.newBuilder().proxyAuthenticator(HostProxyPolicy.authenticatorFor {
                HostProxyPolicy.Policy("PROXY another.invalid:7890", "alice", "secret")
            }).build()
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
    fun malformedPolicyFailsClosed() {
        assertFails { HostProxyPolicy.proxies("") }
        assertFails { HostProxyPolicy.proxies("PROXY user:secret@localhost:7890") }
        assertFails { HostProxyPolicy.proxies("PROXY localhost:0") }
        assertFails { HostProxyPolicy.proxies("SOCKS localhost:1080") }
        assertEquals("Host proxy policy", HostProxyPolicy.Policy("DIRECT", "alice", "secret").toString())
    }
}
