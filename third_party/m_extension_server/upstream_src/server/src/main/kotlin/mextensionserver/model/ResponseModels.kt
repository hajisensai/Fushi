package mextensionserver.model

import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga

// Response models matching mextensionserver format
data class MangaResponse(
    val mangas: List<JManga>? = null,
    val hasNextPage: Boolean? = null,
)

data class AnimeResponse(
    val animes: List<JAnime>? = null,
    val hasNextPage: Boolean? = null,
)

data class PageResponse(
    val pageList: List<JPage>? = null,
)

data class FiltersResponse(
    val filterList: FilterList? = null,
)

data class AnimeFiltersResponse(
    val filterList: AnimeFilterList? = null,
)

data class PreferencesResponse(
    val preferences: List<JPreference>? = null,
)

data class JManga(
    val url: String,
    val title: String,
    val artist: String?,
    val author: String?,
    val description: String?,
    val genre: String?,
    val status: Int,
    val thumbnail_url: String?,
    val initialized: Boolean,
)

data class JAnime(
    val url: String,
    val title: String,
    val artist: String?,
    val author: String?,
    val description: String?,
    val genre: String?,
    val status: Int,
    val thumbnail_url: String?,
    val initialized: Boolean,
)

data class JChapter(
    val url: String,
    val name: String,
    val date_upload: Long,
    val chapter_number: Float,
    val scanlator: String?,
)

data class JEpisode(
    val url: String,
    val name: String,
    val date_upload: Long,
    val episode_number: Float,
    val scanlator: String?,
)

data class JPage(
    val index: Int,
    val url: String,
    val imageUrl: String?,
)

data class JPreference(
    val type: String,
    val props: Map<String, Any>,
)

fun SManga.toJManga(): JManga =
    JManga(
        url = runCatching { this.url }.getOrDefault(""),
        title = runCatching { this.title }.getOrDefault(""),
        artist = runCatching { this.artist }.getOrNull(),
        author = runCatching { this.author }.getOrNull(),
        description = runCatching { this.description }.getOrNull(),
        genre = runCatching { this.genre }.getOrNull(),
        status = runCatching { this.status }.getOrDefault(0),
        thumbnail_url = runCatching { this.thumbnail_url }.getOrNull(),
        initialized = runCatching { this.initialized }.getOrDefault(false),
    )

fun SChapter.toJChapter(): JChapter =
    JChapter(
        url = runCatching { this.url }.getOrDefault(""),
        name = runCatching { this.name }.getOrDefault(""),
        date_upload = runCatching { this.date_upload }.getOrDefault(0L),
        chapter_number = runCatching { this.chapter_number }.getOrDefault(0f),
        scanlator = runCatching { this.scanlator }.getOrNull(),
    )

fun SAnime.toJAnime(): JAnime =
    JAnime(
        url = runCatching { this.url }.getOrDefault(""),
        title = runCatching { this.title }.getOrDefault(""),
        artist = runCatching { this.artist }.getOrNull(),
        author = runCatching { this.author }.getOrNull(),
        description = runCatching { this.description }.getOrNull(),
        genre = runCatching { this.genre }.getOrNull(),
        status = runCatching { this.status }.getOrDefault(0),
        thumbnail_url = runCatching { this.thumbnail_url }.getOrNull(),
        initialized = runCatching { this.initialized }.getOrDefault(false),
    )

fun SEpisode.toJEpisode(): JEpisode =
    JEpisode(
        url = runCatching { this.url }.getOrDefault(""),
        name = runCatching { this.name }.getOrDefault(""),
        date_upload = runCatching { this.date_upload }.getOrDefault(0L),
        episode_number = runCatching { this.episode_number }.getOrDefault(0f),
        scanlator = runCatching { this.scanlator }.getOrNull(),
    )
