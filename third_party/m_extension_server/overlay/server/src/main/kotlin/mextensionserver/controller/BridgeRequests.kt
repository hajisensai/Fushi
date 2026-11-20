package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.ApkNotRegisteredException
import mextensionserver.impl.ApkUploadException
import mextensionserver.impl.ExtensionApkStore
import java.io.IOException

/** A request body this server refuses before reading it; carries its HTTP status. */
internal class RequestBodyException(
    val status: NanoHTTPD.Response.Status,
    message: String,
) : IllegalArgumentException(message)

/**
 * Reads request bodies straight off the socket.
 *
 * Upstream called `session.parseBody`, and NanoHTTPD 2.3.1 spools every body
 * over 1 KB into a `NanoHTTPD-*` temp file that it then memory-maps; on
 * Windows the mapping outlives the request and the delete fails, so a sidecar
 * that lived for a reading session kept one file per bridge call until the JVM
 * exited (BUG-5046). Bridge bodies are small JSON now that APKs travel once by
 * digest, and the one large body -- the APK upload -- is streamed to its file
 * by [ExtensionApkStore.put].
 */
internal object BridgeRequests {
    /** JSON bodies carry digests, filters and preference snapshots, never an APK. */
    const val MAX_JSON_BYTES: Long = 8L * 1024 * 1024

    private val mapper = jacksonObjectMapper()

    fun contentLength(session: NanoHTTPD.IHTTPSession): Long {
        val raw =
            session.headers["content-length"]
                ?: throw RequestBodyException(NanoHTTPD.Response.Status.LENGTH_REQUIRED, "Content-Length is required")
        return raw.trim().toLongOrNull()?.takeIf { it >= 0 }
            ?: throw RequestBodyException(NanoHTTPD.Response.Status.BAD_REQUEST, "Invalid Content-Length")
    }

    fun readJson(session: NanoHTTPD.IHTTPSession): String {
        val length = contentLength(session)
        if (length == 0L) throw RequestBodyException(NanoHTTPD.Response.Status.BAD_REQUEST, "No JSON body")
        if (length > MAX_JSON_BYTES) {
            throw RequestBodyException(
                NanoHTTPD.Response.Status.PAYLOAD_TOO_LARGE,
                "JSON body exceeds $MAX_JSON_BYTES bytes",
            )
        }
        val bytes = ByteArray(length.toInt())
        var offset = 0
        val input = session.inputStream
        while (offset < bytes.size) {
            val read = input.read(bytes, offset, bytes.size - offset)
            if (read < 0) throw IOException("Request body ended after $offset of ${bytes.size} bytes")
            offset += read
        }
        return String(bytes, Charsets.UTF_8)
    }

    /**
     * The body was not (fully) read, so the connection cannot carry another
     * request: whatever is left of this body would be parsed as the next one.
     */
    fun RequestBodyException.toResponse(): NanoHTTPD.Response =
        NanoHTTPD
            .newFixedLengthResponse(
                status,
                "application/json",
                mapper.writeValueAsString(mapOf("error" to message, "errorKind" to "bridge")),
            ).apply { closeConnection(true) }

    /** `409 apkUnknown`: the host uploads the APK and repeats the call once. */
    fun ApkNotRegisteredException.toResponse(): NanoHTTPD.Response =
        NanoHTTPD.newFixedLengthResponse(
            NanoHTTPD.Response.Status.CONFLICT,
            "application/json",
            mapper.writeValueAsString(apkUnknownPayload()),
        )

    fun ApkNotRegisteredException.apkUnknownPayload(): Map<String, Any?> =
        mapOf(
            "error" to message,
            "errorKind" to APK_UNKNOWN,
            "apkSha256" to sha256,
        )

    /** Finds a missing-APK failure however the call wrapped it. */
    fun apkNotRegisteredIn(error: Throwable): ApkNotRegisteredException? =
        generateSequence(error) { it.cause }.filterIsInstance<ApkNotRegisteredException>().firstOrNull()

    const val APK_UNKNOWN = "apkUnknown"
}

/**
 * `PUT /apk/<sha256>` with the raw APK bytes as the body.
 *
 * Storing runs no extension code: the bytes are hashed and written, nothing
 * more. `/inspect` reads them declaratively before the trust prompt; only
 * `/dalvik` (after the user accepted) loads them.
 */
internal class ApkUploadHandler {
    private val mapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        if (session.method != NanoHTTPD.Method.PUT) {
            return NanoHTTPD
                .newFixedLengthResponse(
                    NanoHTTPD.Response.Status.METHOD_NOT_ALLOWED,
                    "application/json",
                    """{"error":"Use PUT"}""",
                ).apply { closeConnection(true) }
        }
        val sha256 = session.uri.removePrefix(ROUTE_PREFIX)
        return try {
            val length = BridgeRequests.contentLength(session)
            ExtensionApkStore.shared.put(sha256, session.inputStream, length)
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/json",
                mapper.writeValueAsString(mapOf("apkSha256" to sha256)),
            )
        } catch (error: RequestBodyException) {
            with(BridgeRequests) { error.toResponse() }
        } catch (error: ApkUploadException) {
            // The body may be only partly consumed (size refused up front, or
            // the stream ended early); never reuse this connection.
            NanoHTTPD
                .newFixedLengthResponse(
                    NanoHTTPD.Response.Status.BAD_REQUEST,
                    "application/json",
                    mapper.writeValueAsString(mapOf("error" to error.message, "errorKind" to "bridge")),
                ).apply { closeConnection(true) }
        } catch (error: Exception) {
            NanoHTTPD
                .newFixedLengthResponse(
                    NanoHTTPD.Response.Status.INTERNAL_ERROR,
                    "application/json",
                    mapper.writeValueAsString(
                        mapOf("error" to (error.message ?: error.javaClass.simpleName), "errorKind" to "bridge"),
                    ),
                ).apply { closeConnection(true) }
        }
    }

    companion object {
        const val ROUTE_PREFIX = "/apk/"
    }
}
