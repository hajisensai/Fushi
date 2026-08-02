package mextensionserver.impl

import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.runBlocking
import java.util.UUID

/**
 * Keeps page requests inside the extension's OkHttp client.
 *
 * Some extensions use interceptors to turn a synthetic page URL into image
 * bytes. Returning that URL to the caller bypasses the interceptor, so page
 * entries are registered here and exposed through a loopback URL instead.
 */
internal object MihonImageProxy {
    private const val MAX_ENTRIES = 4096

    data class ImageData(
        val bytes: ByteArray,
        val contentType: String,
    )

    private data class Entry(
        val key: String,
        val source: HttpSource,
        val page: Page,
    )

    private val lock = Any()
    private val entriesByToken = LinkedHashMap<String, Entry>(16, 0.75f, true)
    private val tokensByKey = mutableMapOf<String, String>()

    @Volatile
    private var port: Int = 0

    fun configure(port: Int) {
        require(port > 0) { "Image proxy port must be positive" }
        this.port = port
    }

    fun register(
        source: HttpSource,
        page: Page,
    ): String? {
        val currentPort = port
        if (currentPort <= 0) return null

        val key =
            buildString {
                append(System.identityHashCode(source))
                append('\u0000')
                append(page.index)
                append('\u0000')
                append(page.url)
                append('\u0000')
                append(page.imageUrl.orEmpty())
            }
        val token =
            synchronized(lock) {
                tokensByKey[key]?.let { existingToken ->
                    entriesByToken[existingToken] = Entry(key, source, page)
                    return@synchronized existingToken
                }

                while (entriesByToken.size >= MAX_ENTRIES) {
                    val iterator = entriesByToken.entries.iterator()
                    val eldest = iterator.next()
                    iterator.remove()
                    tokensByKey.remove(eldest.value.key)
                }

                UUID.randomUUID().toString().also { newToken ->
                    entriesByToken[newToken] = Entry(key, source, page)
                    tokensByKey[key] = newToken
                }
            }

        return "http://127.0.0.1:$currentPort/image/$token"
    }

    fun fetch(token: String): ImageData? {
        val entry = synchronized(lock) { entriesByToken[token] } ?: return null
        if (entry.page.imageUrl == null) {
            entry.page.imageUrl =
                runBlocking {
                    entry.source.getImageUrl(entry.page)
                }
        }
        return entry.source.fetchImage(entry.page).toBlocking().single().use { response ->
            val body = requireNotNull(response.body) { "Extension returned an empty image response" }
            ImageData(
                bytes = body.bytes(),
                contentType = body.contentType()?.toString() ?: "application/octet-stream",
            )
        }
    }

    fun clear() {
        synchronized(lock) {
            entriesByToken.clear()
            tokensByKey.clear()
        }
        port = 0
    }
}
