package mextensionserver.controller

import com.sun.net.httpserver.HttpServer
import fi.iki.elonen.NanoHTTPD
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * manga-18b: the relay must send headers and first bytes while the source is
 * still sending, and must turn a broken source body into a broken relay body
 * instead of a connection that waits for a chunk terminator forever.
 */
class StreamingImageResponseTest {
    private val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    private val client =
        OkHttpClient
            .Builder()
            .proxy(Proxy.NO_PROXY)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    private var relay: NanoHTTPD? = null

    @AfterTest
    fun stop() {
        relay?.stop()
        upstream.stop(0)
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdownNow()
    }

    private fun startRelay(maxBytes: Long?): Int {
        upstream.start()
        val upstreamUrl = "http://127.0.0.1:${upstream.address.port}/image"
        val server =
            object : NanoHTTPD("127.0.0.1", 0) {
                override fun serve(session: IHTTPSession): Response {
                    val response = client.newCall(Request.Builder().url(upstreamUrl).build()).execute()
                    return streamingImageResponse(response, maxBytes)
                }
            }
        server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        relay = server
        return server.listeningPort
    }

    private fun open(port: Int): HttpURLConnection =
        (URI("http://127.0.0.1:$port/").toURL().openConnection(Proxy.NO_PROXY) as HttpURLConnection).apply {
            connectTimeout = 5_000
            readTimeout = 5_000
        }

    @Test
    fun `headers and first bytes reach the host before the source finishes`() {
        val firstHalf = ByteArray(32 * 1024) { 1 }
        val secondHalf = ByteArray(32 * 1024) { 2 }
        val release = CountDownLatch(1)
        upstream.createContext("/image") { exchange ->
            exchange.responseHeaders.add("Content-Type", "image/png")
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.use { body ->
                body.write(firstHalf)
                body.flush()
                release.await(10, TimeUnit.SECONDS)
                body.write(secondHalf)
            }
        }
        val connection = open(startRelay(maxBytes = null))
        try {
            // Buffering relays would block here until [release] -- which only
            // happens after the first half has been observed below.
            assertEquals(200, connection.responseCode)
            assertEquals("image/png", connection.contentType)
            val stream = connection.inputStream
            val head = stream.readNBytes(firstHalf.size)
            assertContentEquals(firstHalf, head)
            release.countDown()
            assertContentEquals(secondHalf, stream.readAllBytes())
        } finally {
            release.countDown()
            connection.disconnect()
        }
    }

    @Test
    fun `a source body that breaks off fails the relay instead of hanging it`() {
        upstream.createContext("/image") { exchange ->
            exchange.responseHeaders.add("Content-Type", "image/jpeg")
            // Promise more than is sent, then drop the connection.
            exchange.sendResponseHeaders(200, 1_000_000)
            exchange.responseBody.write(ByteArray(10_000))
            exchange.responseBody.flush()
            exchange.close()
        }
        val connection = open(startRelay(maxBytes = null))
        try {
            assertEquals(200, connection.responseCode)
            val started = System.nanoTime()
            assertFailsWith<IOException> { connection.inputStream.readAllBytes() }
            val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            assertTrue(elapsedMs < 4_000, "relay hung ${elapsedMs}ms instead of failing")
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun `a capped relay cuts a source that exceeds the cap`() {
        upstream.createContext("/image") { exchange ->
            exchange.responseHeaders.add("Content-Type", "image/jpeg")
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.use { body -> repeat(8) { body.write(ByteArray(16 * 1024)) } }
        }
        val connection = open(startRelay(maxBytes = 64L * 1024))
        try {
            assertFailsWith<IOException> { connection.inputStream.readAllBytes() }
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun `a declared length over the cap is refused before any byte is relayed`() {
        upstream.createContext("/image") { exchange ->
            exchange.responseHeaders.add("Content-Type", "image/jpeg")
            exchange.sendResponseHeaders(200, 128L * 1024)
            exchange.responseBody.use { body -> body.write(ByteArray(128 * 1024)) }
        }
        upstream.start()
        val response =
            client
                .newCall(Request.Builder().url("http://127.0.0.1:${upstream.address.port}/image").build())
                .execute()
        assertFailsWith<IllegalStateException> { streamingImageResponse(response, maxBytes = 64L * 1024) }
    }
}
