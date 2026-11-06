package mextensionserver.controller

import eu.kanade.tachiyomi.animesource.host.AnimeVideoLoader
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.HttpServer
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SAnimeEpisodeUpdate
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Track
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Headers
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
    fun `hosters and their candidates are expanded concurrently`() {
        // 每次 getVideoList / resolveVideo 都是一次真实 HTTP 往返。串行展开时一集的
        // 取流是「几十次往返首尾相接」，客户端等不到就报超时——源明明是好的
        // （BUG-2617）。这里把每次往返钉成 200ms，四个 hoster 各两条候选。
        //
        // 刻意用 `Thread.sleep` 而不是 `delay`：真实 lib-14 扩展在 suspend 函数里做的
        // 就是阻塞的 `execute()` / `awaitSingle()`。用 `delay` 的话，即使把
        // `Dispatchers.IO` 拿掉、退回 `runBlocking` 的单线程，这个测试照样绿——那正是
        // 它要防的回归。
        val step = 200L
        val source =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    (1..4).map { index -> Hoster(hosterUrl = "https://h$index.example", hosterName = "h$index") }

                override suspend fun getVideoList(hoster: Hoster): List<Video> {
                    Thread.sleep(step)
                    return (1..2).map { index ->
                        Video(videoUrl = "", videoTitle = "${hoster.hosterName}-$index", internalData = "${hoster.hosterName}-$index")
                    }
                }

                override suspend fun resolveVideo(video: Video): Video {
                    Thread.sleep(step)
                    return video.copy(videoUrl = "https://cdn.example/${video.internalData}.m3u8")
                }
            }

        val started = System.nanoTime()
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertEquals(8, videos.size)
        // 顺序仍是扩展给的顺序：并发只改墙钟，不改结果。
        assertEquals(
            (1..4).flatMap { h -> (1..2).map { v -> "https://cdn.example/h$h-$v.m3u8" } },
            videos.map { it.videoUrl },
        )
        // hoster 层并发、候选层顺序：理论值约 step(取列表) + 2*step(两条候选) = 600ms，
        // 而全串行是 4*(step + 2*step) = 2400ms。取 6*step 作阈值，两者之间留足余量。
        assertTrue(
            elapsedMs < 6 * step,
            "hoster 应并发展开：全串行需 ≥${4 * (step + 2 * step)}ms，实测 ${elapsedMs}ms",
        )
    }

    @Test
    fun `a candidate without headers inherits the source headers`() {
        val source =
            object : FakeSource() {
                // 不走 super：默认实现要经 Injekt 取 NetworkHelper，测试环境没注册。
                override fun headersBuilder(): Headers.Builder =
                    Headers.Builder().add("Referer", "https://fake.example/")

                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(
                        Hoster(
                            hosterName = "inline",
                            videoList =
                                listOf(
                                    Video(videoUrl = "https://cdn.example/a.mp4", videoTitle = "bare", initialized = true),
                                    Video(
                                        videoUrl = "https://cdn.example/b.mp4",
                                        videoTitle = "own",
                                        headers = Headers.headersOf("Referer", "https://other.example/"),
                                        initialized = true,
                                    ),
                                ),
                        ),
                    )
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        // 没自带头的继承源的防盗链身份；自带头的原样保留，不被源的覆盖。
        assertEquals("https://fake.example/", videos[0].headers?.get("Referer"))
        assertEquals("https://other.example/", videos[1].headers?.get("Referer"))
        // lib-14 的 page url slot 不能在 copy 时丢掉。
        assertEquals("https://cdn.example/a.mp4", videos[0].url)
    }

    @Test
    fun `a failing candidate does not cancel its siblings`() {
        // 并发实现最容易踩的坑：一个 async 抛出会连坐取消同一 scope 里的其它任务，
        // 于是「一个镜像死了」变成「整集取不到流」。
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
                        "alive" ->
                            listOf(
                                Video(videoUrl = "", videoTitle = "boom", internalData = "boom"),
                                Video(videoUrl = "https://alive.example/ok.mp4", videoTitle = "ok", initialized = true),
                            )
                        else -> throw IllegalStateException("hoster down")
                    }

                override suspend fun resolveVideo(video: Video): Video? =
                    if (video.internalData == "boom") throw IllegalStateException("extractor blew up") else video
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        assertEquals(listOf("https://alive.example/ok.mp4"), videos.map { it.videoUrl })
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

    @Test
    fun `lib 16 and lib 17 Video and Hoster descriptors coexist for extension dex linking`() {
        // 描述符取自真 APK 的 dex（2026-10-23 扫 yuzono lib16 47 个 / salmanbappi lib17）：
        // lib16 的 resolveVideo 用 14 参 copy$default（47 个里 23 个），lib17 用带 memo
        // 的 15 参构造。两代任一描述符缺失，对应 APK 在取流处 NoSuchMethodError。
        val marker = Class.forName("kotlin.jvm.internal.DefaultConstructorMarker")
        val lib16Video =
            arrayOf<Class<*>>(
                String::class.java,
                String::class.java,
                Integer::class.java,
                Integer::class.java,
                okhttp3.Headers::class.java,
                java.lang.Boolean.TYPE,
                List::class.java,
                List::class.java,
                List::class.java,
                List::class.java,
                List::class.java,
                List::class.java,
                String::class.java,
                java.lang.Boolean.TYPE,
            )
        val lib17Video = lib16Video + JsonObject::class.java
        val int = java.lang.Integer.TYPE
        Video::class.java.getDeclaredConstructor(*lib16Video)
        Video::class.java.getDeclaredConstructor(*lib16Video, int, marker)
        Video::class.java.getDeclaredConstructor(*lib17Video, int, marker)
        Video::class.java.getDeclaredMethod("copy\$default", Video::class.java, *lib16Video, int, Any::class.java)
        Video::class.java.getDeclaredMethod("copy\$default", Video::class.java, *lib17Video, int, Any::class.java)
        Video::class.java.getDeclaredMethod("getMemo")

        val lib16Hoster =
            arrayOf<Class<*>>(String::class.java, String::class.java, List::class.java, String::class.java, java.lang.Boolean.TYPE)
        Hoster::class.java.getDeclaredConstructor(*lib16Hoster)
        Hoster::class.java.getDeclaredConstructor(*lib16Hoster, int, marker)
        Hoster::class.java.getDeclaredConstructor(*lib16Hoster, JsonObject::class.java, int, marker)
    }

    @Test
    fun `lib 16 style copy keeps the lib 17 memo`() {
        val memo = buildJsonObject { put("token", "abc") }
        val video = Video(videoUrl = "", videoTitle = "x", memo = memo)
        val copied = video.copy(videoUrl = "https://cdn.example/x.m3u8")
        assertEquals(memo, copied.memo)
        assertEquals("https://cdn.example/x.m3u8", copied.videoUrl)
        assertEquals(video.copy(videoUrl = "https://cdn.example/x.m3u8"), copied)
    }

    @Test
    fun `lib 17 resolveVideo reads memo set by getVideoList`() {
        val source =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(Hoster(hosterName = "h", memo = buildJsonObject { put("server", "s1") }))

                override suspend fun getVideoList(hoster: Hoster): List<Video> =
                    listOf(Video(videoTitle = "auto", memo = buildJsonObject { put("id", hoster.memo["server"]!!.jsonPrimitive.content) }))

                override suspend fun resolveVideo(video: Video): Video? =
                    video.copy(videoUrl = "https://cdn.example/${video.memo["id"]!!.jsonPrimitive.content}.m3u8")
            }
        val videos = runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
        assertEquals(listOf("https://cdn.example/s1.m3u8"), videos.map { it.videoUrl })
    }

    @Test
    fun `lib 17 source implementing only getAnimeEpisodeUpdate answers the host details and episode calls`() {
        val source =
            object : FakeSource() {
                val calls = mutableListOf<String>()

                override suspend fun getAnimeEpisodeUpdate(
                    anime: SAnime,
                    episodes: List<SEpisode>,
                    fetchDetails: Boolean,
                    fetchEpisodes: Boolean,
                ): SAnimeEpisodeUpdate {
                    calls += "update(details=$fetchDetails, episodes=$fetchEpisodes)"
                    val details = SAnime.create().apply {
                        url = anime.url
                        title = "Detailed"
                        initialized = true
                    }
                    val list = listOf(SEpisode.create().apply {
                        url = "/ep/9"
                        name = "Nine"
                    })
                    return SAnimeEpisodeUpdate(if (fetchDetails) details else anime, if (fetchEpisodes) list else episodes)
                }
            }
        val anime = SAnime.create().apply {
            url = "/anime/1"
            title = "Bare"
        }
        // The host (MihonInvoker / MihonChannelHandler) still calls the lib-14/16
        // entry points; the request / parse helpers of this source all throw.
        val details = runBlocking { source.getAnimeDetails(anime) }
        val episodes = runBlocking { source.getEpisodeList(anime) }
        assertEquals("Detailed", details.title)
        assertEquals(listOf("/ep/9"), episodes.map { it.url })
        assertEquals(
            listOf("update(details=true, episodes=false)", "update(details=false, episodes=true)"),
            source.calls,
        )
    }

    @Test
    fun `lib 17 override calling super falls back to the legacy helpers without looping`() {
        val source =
            object : FakeSource() {
                override val client = okhttp3.OkHttpClient()

                override fun animeDetailsRequest(anime: SAnime): Request = throw IllegalStateException("legacy details reached")

                override suspend fun getAnimeEpisodeUpdate(
                    anime: SAnime,
                    episodes: List<SEpisode>,
                    fetchDetails: Boolean,
                    fetchEpisodes: Boolean,
                ): SAnimeEpisodeUpdate = super.getAnimeEpisodeUpdate(anime, episodes, fetchDetails, fetchEpisodes)
            }
        val anime = SAnime.create().apply {
            url = "/anime/1"
            title = "Bare"
        }
        val error = assertFailsWith<IllegalStateException> { runBlocking { source.getAnimeDetails(anime) } }
        assertEquals("legacy details reached", error.message)
    }

    @Test
    fun `lib 14 and 16 sources answer the combined call through their own overrides`() {
        val source =
            object : FakeSource() {
                override suspend fun getAnimeDetails(anime: SAnime): SAnime = SAnime.create().apply {
                    url = anime.url
                    title = "From getAnimeDetails"
                }

                override suspend fun getEpisodeList(anime: SAnime): List<SEpisode> =
                    listOf(SEpisode.create().apply {
                        url = "/ep/legacy"
                        name = "Legacy"
                    })
            }
        val anime = SAnime.create().apply {
            url = "/anime/1"
            title = "Bare"
        }
        val update = runBlocking { source.getAnimeEpisodeUpdate(anime, emptyList(), fetchDetails = true, fetchEpisodes = true) }
        assertEquals("From getAnimeDetails", update.anime.title)
        assertEquals(listOf("/ep/legacy"), update.episodes.map { it.url })
    }

    @Test
    fun `placeholder urls are rebased onto the extension local server or fail when the host has none`() {
        val source =
            object : FakeSource() {
                override fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

                override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
                    listOf(
                        Hoster(
                            hosterName = "local",
                            videoList =
                                listOf(
                                    Video(
                                        videoUrl = "${HttpServer.PLACEHOLDER_URL}/stream/1.mkv",
                                        videoTitle = "local",
                                        subtitleTracks = listOf(Track("${HttpServer.PLACEHOLDER_URL}/sub/1.vtt", "en")),
                                        initialized = true,
                                    ),
                                ),
                        ),
                    )
            }
        val videos =
            runBlocking { AnimeVideoLoader.loadVideos(source, episode) { "http://127.0.0.1:40000" } }
        assertEquals(listOf("http://127.0.0.1:40000/stream/1.mkv"), videos.map { it.videoUrl })
        assertEquals("http://127.0.0.1:40000/sub/1.vtt", videos.single().subtitleTracks.single().url)

        val error = assertFailsWith<IllegalStateException> { runBlocking { AnimeVideoLoader.loadVideos(source, episode) } }
        assertTrue(error.message!!.contains("local server"))

        assertTrue(AnimeVideoLoader.isPlaceholder("http://localhost:1"))
        assertTrue(AnimeVideoLoader.isPlaceholder("http://localhost:1?x=1"))
        assertTrue(!AnimeVideoLoader.isPlaceholder("http://localhost:10/x"))
    }
}
