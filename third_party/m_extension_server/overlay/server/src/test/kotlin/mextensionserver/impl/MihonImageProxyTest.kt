package mextensionserver.impl

import com.sun.net.httpserver.HttpServer
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import rx.Observable
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MihonImageProxyTest {
    @Test
    fun `consumes network image body before the observable cancels its call`() {
        val expected = ByteArray(256 * 1024) { (it % 251).toByte() }
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/image") { exchange ->
            exchange.responseHeaders.add("Content-Type", "image/jpeg")
            exchange.sendResponseHeaders(200, expected.size.toLong())
            exchange.responseBody.use { it.write(expected) }
        }
        server.start()
        val networkClient =
            OkHttpClient
                .Builder()
                .proxy(Proxy.NO_PROXY)
                .callTimeout(java.time.Duration.ofSeconds(5))
                .build()
        val source =
            object : TestHttpSource() {
                override val client = networkClient
            }
        try {
            MihonImageProxy.configure(39641)
            val page = Page(0, imageUrl = "http://127.0.0.1:${server.address.port}/image")
            val proxyUrl = requireNotNull(MihonImageProxy.register(source, page))
            val token = URI(proxyUrl).path.substringAfterLast('/')
            val image = requireNotNull(MihonImageProxy.fetch(token))
            assertEquals("image/jpeg", image.contentType)
            assertContentEquals(expected, image.bytes)
        } finally {
            server.stop(0)
            networkClient.connectionPool.evictAll()
            networkClient.dispatcher.executorService.shutdownNow()
        }
    }

    @AfterTest
    fun clearProxy() {
        MihonImageProxy.clear()
    }

    @Test
    fun `fetches images through the extension client`() {
        val source = TestHttpSource()
        val fragment = "{\"name\":\"001.jpg\",\"offset\":55}"
        val page = Page(0, imageUrl = "https://example.test/volume.cbz#$fragment")
        MihonImageProxy.configure(39641)

        val proxyUrl = requireNotNull(MihonImageProxy.register(source, page))
        val token = URI(proxyUrl).path.substringAfterLast('/')
        val image = requireNotNull(MihonImageProxy.fetch(token))

        assertTrue(proxyUrl.startsWith("http://127.0.0.1:39641/image/"))
        assertEquals(fragment, source.seenFragment)
        assertEquals("image/jpeg", image.contentType)
        assertContentEquals(source.imageBytes, image.bytes)
    }

    @Test
    fun `resolves missing image urls through the extension`() {
        val source = TestHttpSource()
        val page = Page(0, url = "/reader-page")
        MihonImageProxy.configure(39641)

        val proxyUrl = requireNotNull(MihonImageProxy.register(source, page))
        val token = URI(proxyUrl).path.substringAfterLast('/')
        MihonImageProxy.fetch(token)

        assertEquals(1, source.imageUrlFetches)
        assertEquals(source.resolvedImageUrl, page.imageUrl)
    }

    @Test
    fun `resolves missing image urls through native 1_6 API`() {
        val source = NativeImageUrlHttpSource()
        val page = Page(0, url = "/reader-page")
        MihonImageProxy.configure(39641)

        val proxyUrl = requireNotNull(MihonImageProxy.register(source, page))
        val token = URI(proxyUrl).path.substringAfterLast('/')
        MihonImageProxy.fetch(token)

        assertEquals(1, source.imageUrlFetches)
        assertEquals(source.resolvedImageUrl, page.imageUrl)
    }

    private open class TestHttpSource : HttpSource() {
        val imageBytes = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xd9.toByte())
        val resolvedImageUrl = "https://example.test/resolved.jpg"
        var seenFragment: String? = null
        var imageUrlFetches = 0

        override val name = "Test source"
        override val lang = "en"
        override val baseUrl = "https://example.test"
        override val supportsLatest = false
        override val client =
            OkHttpClient
                .Builder()
                .addInterceptor { chain ->
                    seenFragment = chain.request().url.fragment
                    Response
                        .Builder()
                        .request(chain.request())
                        .protocol(Protocol.HTTP_1_1)
                        .code(200)
                        .message("OK")
                        .body(imageBytes.toResponseBody("image/jpeg".toMediaType()))
                        .build()
                }.build()

        override fun fetchImageUrl(page: Page): Observable<String> {
            imageUrlFetches++
            return Observable.just(resolvedImageUrl)
        }

        override fun imageRequest(page: Page): Request = Request.Builder().url(requireNotNull(page.imageUrl)).build()

        override fun popularMangaRequest(page: Int): Request = unused()

        override fun popularMangaParse(response: Response): MangasPage = unused()

        override fun searchMangaRequest(
            page: Int,
            query: String,
            filters: FilterList,
        ): Request = unused()

        override fun searchMangaParse(response: Response): MangasPage = unused()

        override fun latestUpdatesRequest(page: Int): Request = unused()

        override fun latestUpdatesParse(response: Response): MangasPage = unused()

        override fun mangaDetailsParse(response: Response): SManga = unused()

        override fun chapterListParse(response: Response): List<SChapter> = unused()

        override fun pageListParse(response: Response): List<Page> = unused()

        override fun imageUrlParse(response: Response): String = unused()

        private fun unused(): Nothing = error("Not used by this test")
    }

    private class NativeImageUrlHttpSource : TestHttpSource() {
        override suspend fun getImageUrl(page: Page): String {
            imageUrlFetches++
            return resolvedImageUrl
        }

        override fun fetchImageUrl(page: Page): Observable<String> = error("The bridge must use getImageUrl")
    }
}
