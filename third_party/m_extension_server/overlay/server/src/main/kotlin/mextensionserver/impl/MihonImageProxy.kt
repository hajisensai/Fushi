package mextensionserver.impl

import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.newCallWithProgress
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.runBlocking
import okhttp3.Response
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

    /**
     * Starts the page's image request and hands back the live response; the
     * caller relays its body and closes it (manga-18b, see
     * `streamingImageResponse`). Returns null for an unknown token.
     */
    fun open(token: String): Response? {
        val entry = synchronized(lock) { entriesByToken[token] } ?: return null
        if (entry.page.imageUrl == null) {
            entry.page.imageUrl =
                runBlocking {
                    entry.source.getImageUrl(entry.page)
                }
        }
        // `HttpSource.fetchImage` is final in this ABI, so no extension
        // replaces it, and it is exactly this call wrapped in an Rx Observable
        // whose unsubscription cancels the call. Going through it would cut the
        // body the moment the observable completed -- the reason upstream had
        // to read the whole image inside onNext before responding.
        val response =
            entry.source.client
                .newCallWithProgress(entry.source.imageRequest(entry.page), entry.page)
                .execute()
        if (!response.isSuccessful) {
            response.close()
            throw HttpException(response.code)
        }
        return response
    }

    fun clear() {
        synchronized(lock) {
            entriesByToken.clear()
            tokensByKey.clear()
        }
        port = 0
    }
}
