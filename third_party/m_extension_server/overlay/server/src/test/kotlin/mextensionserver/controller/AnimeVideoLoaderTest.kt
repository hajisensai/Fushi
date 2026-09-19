package mextensionserver.controller

import eu.kanade.tachiyomi.animesource.host.AnimeVideoLoader
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import okhttp3.Response
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The hosted anime ABI is the union of extensions-lib 14 and 16. These pin the
 * generation switch and the per-video resolution the host applies before a URL
 * reaches the player, without any network: each fake overrides the entry point
 * its generation would, exactly as a real extension's dex does.
 */
class AnimeVideoLoaderTest {
    /** The abstract lib-14 surface, so each fake only overrides what it tests. */
    private abstract class FakeSource : AnimeHttpSource() {
        override val name = "fake"
        override val lang = "en"
        override val baseUrl = "https://fake.example"
        override val supportsLatest = false

        override fun popularAnimeRequest(page: Int): Request = throw UnsupportedOperationException()

        override fun popularAnimeParse(response: Response): AnimesPage = throw UnsupportedOperationException()

        override fun searchAnimeRequest(
            page: Int,
            query: String,
            filters: AnimeFilterList,
        ): Request = throw UnsupportedOperationException()

        override fun searchAnimeParse(response: Response): AnimesPage = throw UnsupportedOperationException()

        override fun latestUpdatesRequest(page: Int): Request = throw UnsupportedOperationException()

        override fun latestUpdatesParse(response: Response): AnimesPage = throw UnsupportedOperationException()

        override fun animeDetailsParse(response: Response): SAnime = throw UnsupportedOperationException()

        override fun episodeListParse(response: Response): List<SEpisode> = throw UnsupportedOperationException()
    }

    private val episode = SEpisode.create().apply {
        url = "/ep/1"
        name = "Episode 1"
    }

    @Test
    fun `lib 14 source without hoster parser is routed through getVideoList and getVideoUrl`() {
        val source =
            object : FakeSource() {
                var videoUrlCalls = 0

                @Suppress("DEPRECATION")
                override suspend fun getVideoList(episode: SEpisode): List<Video> =
                    listOf(
                        Video(url = "https://embed.example/1", quality = "720p", videoUrl = null),
                        Video(url = "https://cdn.example/1080.mp4", quality = "1080p", videoUrl = "https://cdn.example/1080.mp4"),
                    )

                override suspend fun getVideoUrl(video: Video): String {
                    videoUrlCalls++
                    return "https://cdn.example/resolved-${video.url.substringAfterLast('/')}.m3u8"
                }
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        assertEquals(
            listOf("https://cdn.example/resolved-1.m3u8", "https://cdn.example/1080.mp4"),
            videos.map { it.videoUrl },
        )
        assertEquals(1, source.videoUrlCalls)
        assertTrue(videos.all { it.initialized })
    }

    @Test
    fun `lib 16 source with hoster parser expands hosters and applies the extension sort`() {
        val source =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(
                        Hoster(hosterUrl = "https://a.example", hosterName = "A"),
                        Hoster(
                            hosterUrl = "",
                            hosterName = "inline",
                            videoList = listOf(Video(videoUrl = "https://b.example/360.mp4", videoTitle = "360p", resolution = 360)),
                        ),
                        Hoster(hosterUrl = "https://lazy.example", hosterName = "lazy", lazy = true),
                    )

                override suspend fun getVideoList(hoster: Hoster): List<Video> =
                    when (hoster.hosterName) {
                        "A" ->
                            listOf(
                                Video(videoUrl = "https://a.example/480.mp4", videoTitle = "480p", resolution = 480),
                                Video(videoUrl = "https://a.example/1080.mp4", videoTitle = "1080p", resolution = 1080, preferred = true),
                            )
                        else -> error("lazy hoster must not be expanded while eager ones produced videos")
                    }

                override fun List<Video>.sortVideos(): List<Video> = sortedByDescending { it.resolution ?: 0 }
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        assertEquals(
            listOf("https://a.example/1080.mp4", "https://a.example/480.mp4", "https://b.example/360.mp4"),
            videos.map { it.videoUrl },
        )
        assertEquals(listOf(true, false, false), videos.map { it.preferred })
    }

    @Test
    fun `resolveVideo runs once per uninitialised video and a null result drops it`() {
        val source =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(
                        Hoster(
                            hosterName = "inline",
                            videoList =
                                listOf(
                                    Video(videoUrl = "", videoTitle = "needs resolve", internalData = "token-1"),
                                    Video(videoUrl = "", videoTitle = "dead", internalData = "dead"),
                                    Video(videoUrl = "https://c.example/ready.mp4", videoTitle = "ready", initialized = true),
                                ),
                        ),
                    )

                override suspend fun resolveVideo(video: Video): Video? =
                    when (video.internalData) {
                        "token-1" -> video.copy(videoUrl = "https://c.example/${video.internalData}.m3u8")
                        else -> null
                    }
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        assertEquals(
            listOf("https://c.example/token-1.m3u8", "https://c.example/ready.mp4"),
            videos.map { it.videoUrl },
        )
    }

    @Test
    fun `a dead hoster is skipped and the first failure only surfaces when nothing plays`() {
        val source =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(
                        Hoster(hosterUrl = "https://dead.example", hosterName = "dead"),
                        Hoster(hosterUrl = "https://alive.example", hosterName = "alive"),
                    )

                override suspend fun getVideoList(hoster: Hoster): List<Video> =
                    when (hoster.hosterName) {
                        "alive" -> listOf(Video(videoUrl = "https://alive.example/v.mp4", videoTitle = "alive"))
                        else -> throw IllegalStateException("hoster down: ${hoster.hosterName}")
                    }
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        assertEquals(listOf("https://alive.example/v.mp4"), videos.map { it.videoUrl })

        val allDead =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(Hoster(hosterUrl = "https://dead.example", hosterName = "dead"))

                override suspend fun getVideoList(hoster: Hoster): List<Video> = throw IllegalStateException("hoster down")
            }
        val error = assertFailsWith<IllegalStateException> { runBlocking { AnimeVideoLoader.loadVideos(allDead, episode) } }
        assertEquals("hoster down", error.message)
    }

    @Test
    fun `lib 14 deprecated constructors keep url and quality and map null videoUrl to unresolved`() {
        @Suppress("DEPRECATION")
        val legacy = Video(url = "https://embed.example/x", quality = "Auto", videoUrl = null)
        assertEquals("https://embed.example/x", legacy.url)
        assertEquals("Auto", legacy.quality)
        assertEquals("Auto", legacy.videoTitle)
        assertTrue(legacy.isVideoUrlUnresolved)

        val modern = Video(videoUrl = "https://cdn.example/v.m3u8", videoTitle = "1080p", resolution = 1080)
        assertEquals("https://cdn.example/v.m3u8", modern.url)
        assertEquals("1080p", modern.quality)
        assertTrue(!modern.isVideoUrlUnresolved)
    }

    @Test
    fun `lib 14 and lib 16 synthetic default-argument constructors both exist for extension dex linking`() {
        // 扩展 dex 按 JVM 描述符链接，宿主源码层编译过不代表二进制契约成立：
        // lib-14 的 Video(url, quality, videoUrl) 解析到 uri 构造的合成默认参数版本，
        // lib-16 的 Video(url, quality, videoUrl, headers) 解析到六参 deprecated 构造。
        // 任一合成构造缺失，真 APK 在 getVideoList 处 NoSuchMethodError。
        val marker = Class.forName("kotlin.jvm.internal.DefaultConstructorMarker")
        Video::class.java.getDeclaredConstructor(
            String::class.java,
            String::class.java,
            String::class.java,
            android.net.Uri::class.java,
            okhttp3.Headers::class.java,
            java.lang.Integer.TYPE,
            marker,
        )
        Video::class.java.getDeclaredConstructor(
            String::class.java,
            String::class.java,
            String::class.java,
            okhttp3.Headers::class.java,
            List::class.java,
            List::class.java,
            java.lang.Integer.TYPE,
            marker,
        )
    }
}
