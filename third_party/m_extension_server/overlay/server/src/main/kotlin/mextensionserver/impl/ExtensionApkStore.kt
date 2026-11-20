package mextensionserver.impl

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

/** A call named an APK digest this process has never received; the host uploads and retries. */
class ApkNotRegisteredException(
    val sha256: String,
) : IllegalStateException("Extension APK $sha256 is not registered with this server")

/** An upload that cannot be stored: bad digest, wrong size, truncated or mismatching body. */
class ApkUploadException(
    message: String,
) : IllegalArgumentException(message)

/**
 * Content-addressed extension APKs, keyed by lowercase SHA-256.
 *
 * Fushi replaced upstream's "every call carries the whole APK as base64" wire
 * (manga-28): the host uploads an APK's raw bytes once per sidecar process
 * through `PUT /apk/<sha256>`, and every later call names only the digest. A
 * call naming an unknown digest fails with [ApkNotRegisteredException], which
 * the controller turns into `409 {"errorKind":"apkUnknown"}`; the host then
 * uploads and retries once. The sidecar stays the only authority on what it
 * holds, so the host keeps no mirror of "what this process has seen".
 *
 * Files live under the JVM's `java.io.tmpdir`, which the desktop host creates
 * per JVM and deletes when the process exits (BUG-5046); [clear] covers a
 * clean `/stop`.
 */
internal class ExtensionApkStore(
    private val directory: File,
) {
    fun put(
        sha256: String,
        body: InputStream,
        length: Long,
    ) {
        if (!isDigest(sha256)) throw ApkUploadException("APK digest must be 64 lowercase hex characters")
        if (length <= 0 || length > MAX_APK_BYTES) {
            throw ApkUploadException("APK size $length is outside 1..$MAX_APK_BYTES bytes")
        }
        directory.mkdirs()
        val partial = File.createTempFile("upload-", ".part", directory)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var remaining = length
            partial.outputStream().use { output ->
                val buffer = ByteArray(CHUNK_BYTES)
                while (remaining > 0) {
                    val read = body.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    if (read < 0) {
                        throw ApkUploadException("APK upload ended after ${length - remaining} of $length bytes")
                    }
                    digest.update(buffer, 0, read)
                    output.write(buffer, 0, read)
                    remaining -= read
                }
            }
            val actual = hex(digest.digest())
            if (actual != sha256) throw ApkUploadException("APK body hashes to $actual, not $sha256")
            val target = fileFor(sha256)
            try {
                Files.move(partial.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (error: IOException) {
                // Content-addressed: a concurrent upload of the same digest that
                // won the race (or a reader holding the file open on Windows)
                // leaves exactly the bytes we would have written.
                if (!target.isFile) throw error
            }
        } finally {
            partial.delete()
        }
    }

    /** The stored APK file; throws [ApkNotRegisteredException] when absent. */
    fun file(sha256: String): File {
        val file = if (isDigest(sha256)) fileFor(sha256) else null
        if (file == null || !file.isFile) throw ApkNotRegisteredException(sha256)
        return file
    }

    fun read(sha256: String): ByteArray = file(sha256).readBytes()

    fun clear() {
        directory.listFiles()?.forEach { file -> if (file.isFile) file.delete() }
    }

    private fun fileFor(sha256: String): File = File(directory, "$sha256.apk")

    companion object {
        /**
         * The process's store. Lives here rather than on `MExtensionServerLoader`
         * so that `/inspect` and the upload route can reach it without touching
         * the loader, whose job is executing extension code.
         */
        val shared: ExtensionApkStore by lazy {
            ExtensionApkStore(Files.createTempDirectory("fushi-apks").toFile())
        }

        /** Real extension APKs are tens to hundreds of KB; far below the 512 MiB heap. */
        const val MAX_APK_BYTES: Long = 64L * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024
        private val DIGEST = Regex("^[0-9a-f]{64}$")

        /** Also the path-traversal guard: only a bare digest ever becomes a file name. */
        fun isDigest(value: String): Boolean = DIGEST.matches(value)

        fun hex(bytes: ByteArray): String = bytes.joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}
