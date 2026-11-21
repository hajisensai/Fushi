package mextensionserver.impl

import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class ExtensionApkStoreTest {
    private val directory = Files.createTempDirectory("apk-store-test").toFile()
    private val store = ExtensionApkStore(directory)
    private val apk = ByteArray(200_000) { (it % 251).toByte() }
    private val digest = ExtensionApkStore.hex(MessageDigest.getInstance("SHA-256").digest(apk))

    @AfterTest
    fun cleanUp() {
        directory.deleteRecursively()
    }

    @Test
    fun `stores an upload under its digest and reads it back`() {
        store.put(digest, ByteArrayInputStream(apk), apk.size.toLong())

        assertContentEquals(apk, store.read(digest))
        assertEquals(listOf("$digest.apk"), directory.list()!!.toList())
    }

    @Test
    fun `an unknown digest is reported as not registered`() {
        val error = assertFailsWith<ApkNotRegisteredException> { store.read(digest) }
        assertEquals(digest, error.sha256)
    }

    @Test
    fun `a body that does not hash to the named digest is refused and leaves nothing behind`() {
        val wrong = "0".repeat(64)
        assertFailsWith<ApkUploadException> {
            store.put(wrong, ByteArrayInputStream(apk), apk.size.toLong())
        }
        assertFailsWith<ApkNotRegisteredException> { store.read(wrong) }
        assertTrue(directory.list()!!.isEmpty(), "partial upload must be deleted")
    }

    @Test
    fun `a body shorter than its declared length is refused`() {
        assertFailsWith<ApkUploadException> {
            store.put(digest, ByteArrayInputStream(apk, 0, 1000), apk.size.toLong())
        }
        assertFailsWith<ApkNotRegisteredException> { store.read(digest) }
        assertTrue(directory.list()!!.isEmpty())
    }

    @Test
    fun `only bare lowercase digests become file names`() {
        for (name in listOf("../escape", digest.uppercase(), digest.dropLast(1), "$digest/..")) {
            assertFailsWith<ApkUploadException> { store.put(name, ByteArrayInputStream(apk), apk.size.toLong()) }
            assertFailsWith<ApkNotRegisteredException> { store.file(name) }
        }
    }

    @Test
    fun `oversized and empty uploads are refused before reading`() {
        assertFailsWith<ApkUploadException> {
            store.put(digest, ByteArrayInputStream(apk), ExtensionApkStore.MAX_APK_BYTES + 1)
        }
        assertFailsWith<ApkUploadException> { store.put(digest, ByteArrayInputStream(apk), 0) }
    }

    @Test
    fun `concurrent uploads of one digest all succeed with identical content`() {
        val executor = Executors.newFixedThreadPool(4)
        try {
            val futures =
                List(8) {
                    executor.submit { store.put(digest, ByteArrayInputStream(apk), apk.size.toLong()) }
                }
            futures.forEach { it.get(10, TimeUnit.SECONDS) }
        } finally {
            executor.shutdownNow()
        }
        assertContentEquals(apk, store.read(digest))
        assertEquals(listOf("$digest.apk"), directory.list()!!.toList())
    }

    @Test
    fun `clear forgets every upload`() {
        store.put(digest, ByteArrayInputStream(apk), apk.size.toLong())
        store.clear()
        assertFailsWith<ApkNotRegisteredException> { store.read(digest) }
    }
}
