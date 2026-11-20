package mextensionserver.controller

import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.ExtensionApkStore
import java.io.File
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URI
import java.security.MessageDigest
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class BridgeRequestsTest {
    private var server: NanoHTTPD? = null

    @AfterTest
    fun stop() {
        server?.stop()
    }

    private fun start(): Int {
        val started =
            object : NanoHTTPD("127.0.0.1", 0) {
                override fun serve(session: IHTTPSession): Response =
                    if (session.uri.startsWith(ApkUploadHandler.ROUTE_PREFIX)) {
                        ApkUploadHandler().serve(session)
                    } else {
                        try {
                            newFixedLengthResponse(Response.Status.OK, "application/json", BridgeRequests.readJson(session))
                        } catch (error: RequestBodyException) {
                            with(BridgeRequests) { error.toResponse() }
                        }
                    }
            }
        started.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        server = started
        return started.listeningPort
    }

    private fun send(
        port: Int,
        method: String,
        path: String,
        body: ByteArray,
    ): Pair<Int, String> {
        val connection =
            URI("http://127.0.0.1:$port$path").toURL().openConnection(Proxy.NO_PROXY) as HttpURLConnection
        connection.requestMethod = method
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(body.size)
        connection.outputStream.use { it.write(body) }
        val code = connection.responseCode
        val text = (if (code < 400) connection.inputStream else connection.errorStream).use { String(it.readAllBytes()) }
        connection.disconnect()
        return code to text
    }

    private fun nanoTempFiles(): Set<String> =
        File(System.getProperty("java.io.tmpdir")).list { _, name -> name.startsWith("NanoHTTPD-") }?.toSet().orEmpty()

    @Test
    fun `JSON bodies are read without NanoHTTPD spooling them to temp files`() {
        val port = start()
        val before = nanoTempFiles()
        val json = """{"apkSha256":"${"a".repeat(64)}","pad":"${"x".repeat(16 * 1024)}"}"""
        repeat(20) {
            val (code, echoed) = send(port, "POST", "/dalvik", json.toByteArray())
            assertEquals(200, code)
            assertEquals(json, echoed)
        }
        // parseBody would have left one NanoHTTPD-* file per body over 1 KB (BUG-4914).
        assertEquals(emptySet(), nanoTempFiles() - before)
    }

    @Test
    fun `an APK uploaded by digest is stored and a mismatching body is refused`() {
        val port = start()
        val apk = ByteArray(300_000) { (it * 7).toByte() }
        val digest = ExtensionApkStore.hex(MessageDigest.getInstance("SHA-256").digest(apk))

        val (code, _) = send(port, "PUT", "/apk/$digest", apk)
        assertEquals(200, code)
        assertContentEquals(apk, ExtensionApkStore.shared.read(digest))

        val other = "b".repeat(64)
        val (refused, _) = send(port, "PUT", "/apk/$other", apk)
        assertEquals(400, refused)
    }

    @Test
    fun `uploads must use PUT`() {
        val port = start()
        val (code, _) = send(port, "POST", "/apk/${"c".repeat(64)}", byteArrayOf(1))
        assertEquals(405, code)
    }
}
