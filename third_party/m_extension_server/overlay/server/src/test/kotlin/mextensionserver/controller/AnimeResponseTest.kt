package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.Track
import eu.kanade.tachiyomi.animesource.model.Video
import okhttp3.Headers
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Aniyomi (anime) responses cross the same `/dalvik` wire as manga ones. These
 * pin the two projections the host decodes: the explicit filter shape shared
 * with manga, and the `Video` projection that hides okhttp `Headers` and the
 * transient download-progress fields.
 */
class AnimeResponseTest {
    private class Label {
        override fun toString(): String = "字幕"
    }

    @Test
    fun `anime filter list uses the same wire shape as manga filters`() {
        val filters =
            AnimeFilterList(
                object : AnimeFilter.Select<Label>("音声", arrayOf(Label())) {},
                object : AnimeFilter.Group<AnimeFilter<*>>(
                    "ジャンル",
                    listOf(object : AnimeFilter.TriState("完結", AnimeFilter.TriState.STATE_EXCLUDE) {}),
                ) {},
                object : AnimeFilter.Sort("更新", arrayOf("新着"), AnimeFilter.Sort.Selection(0, false)) {},
                object : AnimeFilter.Text("検索") {},
            )
        val mapper = jacksonObjectMapper()
        val json = mapper.readTree(mapper.writeValueAsString(filterResponseForBridge(filters)))
        assertTrue(json.isArray)
        assertEquals("select", json[0]["type"].asText())
        assertEquals("字幕", json[0]["values"][0].asText())
        assertEquals("group", json[1]["type"].asText())
        assertEquals("triState", json[1]["children"][0]["type"].asText())
        assertEquals(2, json[1]["children"][0]["state"].asInt())
        assertEquals("sort", json[2]["type"].asText())
        assertEquals(false, json[2]["state"]["ascending"].asBoolean())
        assertEquals("text", json[3]["type"].asText())
    }

    @Test
    fun `video list projects url quality headers and tracks only`() {
        val videos =
            listOf(
                Video(
                    url = "https://cdn.example/ep1.m3u8",
                    quality = "1080p",
                    videoUrl = "https://cdn.example/ep1.m3u8",
                    headers = Headers.headersOf("Referer", "https://site.example/", "User-Agent", "Fushi"),
                    subtitleTracks = listOf(Track("https://cdn.example/ja.vtt", "日本語")),
                ),
                Video(url = "https://cdn.example/ep1-720.mp4", quality = "720p", videoUrl = null),
            )
        val mapper = jacksonObjectMapper()
        val json = mapper.readTree(mapper.writeValueAsString(filterResponseForBridge(videos)))
        assertTrue(json.isArray)
        assertEquals(2, json.size())
        assertEquals("1080p", json[0]["quality"].asText())
        assertEquals("https://site.example/", json[0]["headers"]["Referer"].asText())
        assertEquals("Fushi", json[0]["headers"]["User-Agent"].asText())
        assertEquals("https://cdn.example/ja.vtt", json[0]["subtitleTracks"][0]["url"].asText())
        assertEquals("日本語", json[0]["subtitleTracks"][0]["lang"].asText())
        assertEquals(
            setOf(
                "url", "quality", "videoUrl", "videoTitle", "resolution", "bitrate", "preferred",
                "headers", "subtitleTracks", "audioTracks", "mpvArgs",
            ),
            json[0].fieldNames().asSequence().toSet(),
        )
        assertEquals("1080p", json[0]["videoTitle"].asText())
        assertTrue(json[0]["resolution"].isNull)
        assertEquals(false, json[0]["preferred"].asBoolean())
        // The lib-16 deprecated constructor stores a null videoUrl as the string
        // "null"; the wire keeps the lib-14 meaning.
        assertTrue(json[1]["videoUrl"].isNull)
        assertEquals("https://cdn.example/ep1-720.mp4", json[1]["url"].asText())
        assertTrue(json[1]["headers"].isNull)
    }

    @Test
    fun `lib 16 videos project title resolution preferred and mpv args`() {
        val videos =
            listOf(
                Video(
                    videoUrl = "https://cdn.example/1080.m3u8",
                    videoTitle = "Japanese - 1080p",
                    resolution = 1080,
                    bitrate = 4_000_000,
                    preferred = true,
                    mpvArgs = listOf("http-header-fields" to "Referer: https://site.example/"),
                ),
            )
        val mapper = jacksonObjectMapper()
        val json = mapper.readTree(mapper.writeValueAsString(filterResponseForBridge(videos)))
        assertEquals("Japanese - 1080p", json[0]["videoTitle"].asText())
        assertEquals("Japanese - 1080p", json[0]["quality"].asText())
        assertEquals("https://cdn.example/1080.m3u8", json[0]["url"].asText())
        assertEquals(1080, json[0]["resolution"].asInt())
        assertEquals(4_000_000, json[0]["bitrate"].asInt())
        assertEquals(true, json[0]["preferred"].asBoolean())
        assertEquals("http-header-fields", json[0]["mpvArgs"][0]["key"].asText())
    }

    @Test
    fun `non video lists and empty lists pass through untouched`() {
        val episodes = listOf(mapOf("url" to "/ep/1"))
        assertSame(episodes, filterResponseForBridge(episodes))
        val empty = emptyList<Any>()
        assertSame(empty, filterResponseForBridge(empty))
    }

    @Test
    fun `lib gate accepts manga 1_4 and 1_6 and anime 14 to 16`() {
        assertEquals("1.4", InspectHandler.supportedLibVersionLabel("manga", 1.4))
        assertEquals("1.6", InspectHandler.supportedLibVersionLabel("manga", 1.6))
        assertNull(InspectHandler.supportedLibVersionLabel("manga", 14.0))
        assertEquals("14", InspectHandler.supportedLibVersionLabel("anime", 14.0))
        // The hosted anime ABI is the lib 14 + lib 16 union (hoster API, the
        // data-class Video); both generations install.
        assertEquals("15", InspectHandler.supportedLibVersionLabel("anime", 15.0))
        assertEquals("16", InspectHandler.supportedLibVersionLabel("anime", 16.0))
        assertNull(InspectHandler.supportedLibVersionLabel("anime", 17.0))
        assertNull(InspectHandler.supportedLibVersionLabel("anime", 1.6))
        assertNull(InspectHandler.supportedLibVersionLabel("anime", null))
    }
}
