package app.fushi.reader.mihon

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.TreeMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/**
 * The slice of `com.sun.net.httpserver.HttpServer` these tests use, same names and semantics.
 *
 * Android unit tests compile against android.jar, which has no `jdk.httpserver` module, so
 * importing the real one made this whole test source set fail to compile. One request per
 * connection (`Connection: close`); `sendResponseHeaders(code, 0)` streams chunked, `-1` sends
 * no body; an exchange the handler never closes stays open until [stop], like the real server.
 */
class HttpServer private constructor(private val server: ServerSocket) {
    private val contexts = CopyOnWriteArrayList<Pair<String, (Exchange) -> Unit>>()
    private val connections = CopyOnWriteArrayList<Socket>()

    val address: InetSocketAddress
        get() = InetSocketAddress(server.inetAddress, server.localPort)

    fun createContext(path: String, handler: (Exchange) -> Unit) {
        contexts += path to handler
    }

    fun start() {
        thread(isDaemon = true, name = "test-http-accept") {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                connections += socket
                thread(isDaemon = true, name = "test-http-exchange") { runCatching { serve(socket) } }
            }
        }
    }

    fun stop(@Suppress("UNUSED_PARAMETER") delay: Int) {
        server.close()
        connections.forEach { runCatching { it.close() } }
    }

    private fun serve(socket: Socket) {
        val input = BufferedInputStream(socket.getInputStream())
        val target = readLine(input)?.split(' ')?.getOrNull(1) ?: return socket.close()
        val requestHeaders = Headers()
        while (true) {
            val line = readLine(input) ?: return socket.close()
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) requestHeaders.add(line.substring(0, colon).trim(), line.substring(colon + 1).trim())
        }
        var remaining = requestHeaders.getFirst("Content-Length")?.toLongOrNull() ?: 0L
        while (remaining > 0 && input.read() >= 0) remaining--
        val uri = URI(target)
        val path = uri.rawPath?.ifEmpty { null } ?: "/"
        val handler = contexts.filter { path.startsWith(it.first) }.maxByOrNull { it.first.length }?.second
            ?: return socket.close()
        handler(Exchange(uri, requestHeaders, socket))
    }

    private fun readLine(input: InputStream): String? {
        val bytes = java.io.ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return if (bytes.size() == 0) null else bytes.toString(Charsets.ISO_8859_1.name())
            if (b == '\n'.code) return bytes.toString(Charsets.ISO_8859_1.name()).removeSuffix("\r")
            bytes.write(b)
        }
    }

    class Headers {
        private val values = TreeMap<String, MutableList<String>>(String.CASE_INSENSITIVE_ORDER)

        fun add(name: String, value: String) {
            values.getOrPut(name) { mutableListOf() } += value
        }

        fun getFirst(name: String): String? = values[name]?.firstOrNull()

        internal fun lines(): List<String> = values.flatMap { (name, list) -> list.map { "$name: $it" } }
    }

    class Exchange internal constructor(
        val requestURI: URI,
        val requestHeaders: Headers,
        private val socket: Socket,
    ) {
        val responseHeaders = Headers()
        private val raw = BufferedOutputStream(socket.getOutputStream())
        private var body: OutputStream? = null

        val responseBody: OutputStream
            get() = body ?: error("sendResponseHeaders first")

        fun sendResponseHeaders(code: Int, length: Long) {
            val framing = when {
                length > 0 -> "Content-Length: $length"
                length == 0L -> "Transfer-Encoding: chunked"
                else -> "Content-Length: 0"
            }
            val head = buildString {
                append("HTTP/1.1 $code Status\r\n")
                responseHeaders.lines().forEach { append(it).append("\r\n") }
                append("Connection: close\r\n").append(framing).append("\r\n\r\n")
            }
            raw.write(head.toByteArray(Charsets.ISO_8859_1))
            raw.flush()
            body = if (length == 0L) ChunkedBody() else PlainBody()
        }

        fun close() {
            runCatching { body?.close() }
            runCatching { socket.close() }
        }

        private inner class PlainBody : OutputStream() {
            override fun write(b: Int) = raw.write(b)
            override fun write(b: ByteArray, off: Int, len: Int) = raw.write(b, off, len)
            override fun flush() = raw.flush()
            override fun close() {
                raw.flush()
                socket.close()
            }
        }

        private inner class ChunkedBody : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
            override fun write(b: ByteArray, off: Int, len: Int) {
                if (len == 0) return
                raw.write("${Integer.toHexString(len)}\r\n".toByteArray(Charsets.ISO_8859_1))
                raw.write(b, off, len)
                raw.write("\r\n".toByteArray(Charsets.ISO_8859_1))
            }
            override fun flush() = raw.flush()
            override fun close() {
                raw.write("0\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                raw.flush()
                socket.close()
            }
        }
    }

    companion object {
        fun create(address: InetSocketAddress, backlog: Int): HttpServer =
            HttpServer(ServerSocket(address.port, backlog, address.address))
    }
}
