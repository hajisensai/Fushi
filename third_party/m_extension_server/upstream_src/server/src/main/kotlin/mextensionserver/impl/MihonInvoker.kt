package mextensionserver.impl

import android.app.Application
import androidx.preference.CheckBoxPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource
import eu.kanade.tachiyomi.animesource.ConfigurableAnimeSource
import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.runBlocking
import mextensionserver.model.AnimeData
import mextensionserver.model.AnimeResponse
import mextensionserver.model.ChapterData
import mextensionserver.model.DataBody
import mextensionserver.model.EpisodeData
import mextensionserver.model.JAnime
import mextensionserver.model.JFilterList
import mextensionserver.model.JManga
import mextensionserver.model.JPage
import mextensionserver.model.MangaData
import mextensionserver.model.MangaResponse
import mextensionserver.model.toJAnime
import mextensionserver.model.toJManga
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

object MihonInvoker {
    private val logger = KotlinLogging.logger {}
    private const val BRIDGE_CONTEXT_KEY = "__mangatan_bridge_context__"
    private val context: Application
        get() = Injekt.get()

    fun invokeMethod(
        loadedExtension: MExtensionServerLoader.LoadedExtension,
        data: DataBody,
    ): Any {
        if (data.method == "sourcesManga" || data.method == "sourcesAnime") {
            return loadedExtension.sources.map(::sourceDescriptor)
        }

        val source = selectSource(loadedExtension.sources, data)

        preparePreferences(data, source)

        return when (data.method) {
            "headersManga" -> invokeHeadersManga(source as Source)
            "filtersManga" -> invokeFiltersManga(source as Source)
            "supportLatestManga" -> invokeSupportLatestManga(source as Source)
            "getPopularManga" -> invokeGetPopularManga(source as Source, data.page ?: 1)
            "getLatestManga" -> invokeGetLatestManga(source as Source, data.page ?: 1)
            "getSearchManga" -> invokeGetSearchManga(source as Source, data.page ?: 1, data.search ?: "", data.filterList)
            "getDetailsManga" -> invokeGetDetailsManga(source as Source, data.mangaData)
            "getMangaUrl" -> invokeGetMangaUrl(source as Source, data.mangaData)
            "getChapterList" -> invokeGetChapterList(source as Source, data.mangaData)
            "getChapterUrl" -> invokeGetChapterUrl(source as Source, data.chapterData)
            "getPageList" -> invokeGetPageList(source as Source, data.chapterData)
            "preferencesManga" -> invokePreferencesManga(source as Source)
            "setPreferenceManga" -> invokeSetPreferenceManga(source as Source, data)
            "headersAnime" -> invokeHeadersAnime(source as AnimeCatalogueSource)
            "filtersAnime" -> invokeFiltersAnime(source as AnimeCatalogueSource)
            "supportLatestAnime" -> invokeSupportLatestAnime(source as AnimeCatalogueSource)
            "getPopularAnime" -> invokeGetPopularAnime(source as AnimeCatalogueSource, data.page ?: 1)
            "getLatestAnime" -> invokeGetLatestAnime(source as AnimeCatalogueSource, data.page ?: 1)
            "getSearchAnime" -> invokeGetSearchAnime(source as AnimeCatalogueSource, data.page ?: 1, data.search ?: "", data.filterList)
            "getDetailsAnime" -> invokeGetDetailsAnime(source as AnimeCatalogueSource, data.animeData)
            "getAnimeUrl" -> invokeGetAnimeUrl(source as AnimeCatalogueSource, data.animeData)
            "getEpisodeList" -> invokeGetEpisodeList(source as AnimeCatalogueSource, data.animeData)
            "getEpisodeUrl" -> invokeGetEpisodeUrl(source as AnimeCatalogueSource, data.episodeData)
            "getVideoList" -> invokeGetVideoList(source as AnimeCatalogueSource, data.episodeData)
            "preferencesAnime" -> invokePreferencesAnime(source as AnimeCatalogueSource)
            "setPreferenceAnime" -> invokeSetPreferenceAnime(source as AnimeCatalogueSource, data)
            else -> throw IllegalArgumentException("Unknown method: ${data.method}")
        }
    }

    fun selectSource(
        loadedSources: List<Any>,
        data: DataBody,
    ): Any {
        if (loadedSources.isEmpty()) {
            throw IllegalArgumentException("No sources found in extension")
        }
        val requestedSourceId =
            bridgeContext(data)["sourceId"]?.toString()
                ?: return loadedSources.first()
        return loadedSources.firstOrNull { sourceId(it) == requestedSourceId }
            ?: throw IllegalArgumentException("Source $requestedSourceId was not found in extension")
    }

    private fun sourceId(source: Any): String =
        when (source) {
            is Source -> source.id.toString()
            is eu.kanade.tachiyomi.animesource.AnimeSource -> source.id.toString()
            else -> throw IllegalArgumentException("Unknown source type: ${source.javaClass}")
        }

    private fun sourceDescriptor(source: Any): Map<String, String> =
        when (source) {
            is Source ->
                mapOf(
                    "id" to source.id.toString(),
                    "name" to source.name,
                    "lang" to source.lang,
                    "baseUrl" to
                        if (source is HttpSource) {
                            runCatching(source::getHomeUrl).getOrDefault(source.baseUrl)
                        } else {
                            ""
                        },
                )
            is eu.kanade.tachiyomi.animesource.AnimeSource ->
                mapOf(
                    "id" to source.id.toString(),
                    "name" to source.name,
                    "lang" to source.lang,
                    "baseUrl" to
                        runCatching {
                            source.javaClass
                                .getMethod("getBaseUrl")
                                .invoke(source)
                                ?.toString()
                                .orEmpty()
                        }.getOrDefault(""),
                )
            else -> throw IllegalArgumentException("Unknown source type: ${source.javaClass}")
        }

    private fun bridgeContext(data: DataBody): Map<String, Any> =
        data.preferences
            ?.firstOrNull { it["key"] == BRIDGE_CONTEXT_KEY }
            .orEmpty()

    fun preparePreferences(
        data: DataBody,
        source: Any,
    ) {
        val changedKey =
            if (data.method.startsWith("setPreference")) {
                bridgeContext(data)["changedPreferenceKey"]?.toString()
            } else {
                null
            }
        applyPreferences(data, source, skipPreferenceKey = changedKey)
    }

    private fun invokeHeadersManga(source: Source): List<String> =
        if (source is HttpSource) {
            val headers =
                source.headers.toMultimap().flatMap { (name, values) ->
                    values.flatMap { value ->
                        listOf(name.replaceFirstChar { it.uppercase() }, value)
                    }
                }
            headers
        } else {
            emptyList()
        }

    private fun invokeFiltersManga(source: Source): FilterList {
        val filterList = source.getFilterList()
        return filterList
    }

    private fun invokeSupportLatestManga(source: Source): Boolean = source.supportsLatest

    private fun invokeGetPopularManga(
        source: Source,
        page: Int,
    ): MangaResponse =
        runBlocking {
            val mangasPage = source.getPopularManga(page)
            MangaResponse(
                mangas =
                    mangasPage.mangas.map { manga ->
                        MihonMetadataCache.remember(source, manga)
                        manga.toJManga()
                    },
                hasNextPage = mangasPage.hasNextPage,
            )
        }

    private fun invokeGetLatestManga(
        source: Source,
        page: Int,
    ): MangaResponse =
        runBlocking {
            val mangasPage = source.getLatestUpdates(page)
            MangaResponse(
                mangas =
                    mangasPage.mangas.map { manga ->
                        MihonMetadataCache.remember(source, manga)
                        manga.toJManga()
                    },
                hasNextPage = mangasPage.hasNextPage,
            )
        }

    private fun invokeGetSearchManga(
        source: Source,
        page: Int,
        search: String,
        filterList: List<JFilterList>?,
    ): MangaResponse =
        runBlocking {
            val convertedFilters = filterList?.let { convertFilterList(source.getFilterList(), it) } ?: source.getFilterList()
            val mangasPage = source.getSearchManga(page, search, convertedFilters)
            MangaResponse(
                mangas =
                    mangasPage.mangas.map { manga ->
                        MihonMetadataCache.remember(source, manga)
                        manga.toJManga()
                    },
                hasNextPage = mangasPage.hasNextPage,
            )
        }

    private fun invokeGetDetailsManga(
        source: Source,
        mangaData: MangaData?,
    ): JManga {
        if (mangaData == null) {
            throw IllegalArgumentException("mangaData is required for getDetailsManga")
        }

        return runBlocking {
            val detailedManga =
                source
                    .getMangaUpdate(
                        manga = mangaData.toSManga(source),
                        chapters = emptyList(),
                        fetchDetails = true,
                        fetchChapters = false,
                    ).manga
            MihonMetadataCache.remember(source, detailedManga)
            detailedManga.toJManga()
        }
    }

    private fun invokeGetMangaUrl(
        source: Source,
        mangaData: MangaData?,
    ): String {
        if (mangaData == null) {
            throw IllegalArgumentException("mangaData is required for getMangaUrl")
        }
        if (source !is HttpSource) {
            throw IllegalArgumentException("Source must be HttpSource for getMangaUrl")
        }
        return source.getMangaUrl(mangaData.toSManga(source))
    }

    private fun invokeGetChapterList(
        source: Source,
        mangaData: MangaData?,
    ): List<SChapter> {
        if (mangaData == null) {
            throw IllegalArgumentException("mangaData is required for getChapterList")
        }

        return runBlocking {
            val chapters =
                source
                    .getMangaUpdate(
                        manga = mangaData.toSManga(source),
                        chapters = emptyList(),
                        fetchDetails = false,
                        fetchChapters = true,
                    ).chapters
            chapters.onEach { chapter -> MihonMetadataCache.remember(source, chapter) }
        }
    }

    private fun invokeGetChapterUrl(
        source: Source,
        chapterData: ChapterData?,
    ): String {
        if (chapterData == null) {
            throw IllegalArgumentException("chapterData is required for getChapterUrl")
        }
        if (source !is HttpSource) {
            throw IllegalArgumentException("Source must be HttpSource for getChapterUrl")
        }
        return source.getChapterUrl(chapterData.toSChapter(source))
    }

    private fun invokeGetPageList(
        source: Source,
        chapterData: ChapterData?,
    ): List<JPage> {
        if (chapterData == null) {
            throw IllegalArgumentException("chapterData is required for getPageList")
        }

        return runBlocking {
            val pages = source.getPageList(chapterData.toSChapter(source))
            pages.map { page ->
                JPage(
                    index = page.index,
                    url = page.url,
                    imageUrl =
                        if (source is HttpSource) {
                            MihonImageProxy.register(source, page)
                                ?: run {
                                    if (page.imageUrl == null) {
                                        page.imageUrl = source.getImageUrl(page)
                                    }
                                    source.imageRequest(page).url.toString()
                                }
                        } else {
                            page.imageUrl ?: page.url
                        },
                )
            }
        }
    }

    private fun invokeHeadersAnime(source: AnimeCatalogueSource): List<String> =
        if (source is AnimeHttpSource) {
            val headers =
                source.headers.toMultimap().flatMap { (name, values) ->
                    values.flatMap { value ->
                        listOf(name.replaceFirstChar { it.uppercase() }, value)
                    }
                }
            headers
        } else {
            emptyList()
        }

    private fun invokeFiltersAnime(source: AnimeCatalogueSource): AnimeFilterList {
        val filterList = source.getFilterList()
        return filterList
    }

    private fun invokeSupportLatestAnime(source: AnimeCatalogueSource): Boolean = source.supportsLatest

    private fun invokeGetPopularAnime(
        source: AnimeCatalogueSource,
        page: Int,
    ): AnimeResponse =
        runBlocking {
            val animesPage = source.getPopularAnime(page)
            AnimeResponse(
                animes = animesPage.animes.map { it.toJAnime() },
                hasNextPage = animesPage.hasNextPage,
            )
        }

    private fun invokeGetLatestAnime(
        source: AnimeCatalogueSource,
        page: Int,
    ): AnimeResponse =
        runBlocking {
            val animesPage = source.getLatestUpdates(page)
            AnimeResponse(
                animes = animesPage.animes.map { it.toJAnime() },
                hasNextPage = animesPage.hasNextPage,
            )
        }

    private fun invokeGetSearchAnime(
        source: AnimeCatalogueSource,
        page: Int,
        search: String,
        filterList: List<JFilterList>?,
    ): AnimeResponse =
        runBlocking {
            val convertedFilters = filterList?.let { convertAnimeFilterList(source.getFilterList(), it) } ?: source.getFilterList()
            val animesPage = source.getSearchAnime(page, search, convertedFilters)
            AnimeResponse(
                animes = animesPage.animes.map { it.toJAnime() },
                hasNextPage = animesPage.hasNextPage,
            )
        }

    private fun invokeGetDetailsAnime(
        source: AnimeCatalogueSource,
        animeData: AnimeData?,
    ): JAnime {
        if (animeData == null) {
            throw IllegalArgumentException("animeData is required for getDetailsAnime")
        }

        if (source !is AnimeHttpSource) {
            throw IllegalArgumentException("Source must be AnimeHttpSource for getDetailsAnime")
        }

        return runBlocking {
            val detailedAnime = source.getAnimeDetails(animeData.toSAnime())
            detailedAnime.toJAnime()
        }
    }

    private fun invokeGetAnimeUrl(
        source: AnimeCatalogueSource,
        animeData: AnimeData?,
    ): String {
        if (animeData == null) {
            throw IllegalArgumentException("animeData is required for getAnimeUrl")
        }
        if (source !is AnimeHttpSource) {
            throw IllegalArgumentException("Source must be AnimeHttpSource for getAnimeUrl")
        }
        return source.getAnimeUrl(animeData.toSAnime())
    }

    private fun invokeGetEpisodeList(
        source: AnimeCatalogueSource,
        animeData: AnimeData?,
    ): List<SEpisode> {
        if (animeData == null) {
            throw IllegalArgumentException("animeData is required for getEpisodeList")
        }

        if (source !is AnimeHttpSource) {
            throw IllegalArgumentException("Source must be AnimeHttpSource for getEpisodeList")
        }

        return runBlocking {
            val episodes = source.getEpisodeList(animeData.toSAnime())
            episodes
        }
    }

    private fun invokeGetEpisodeUrl(
        source: AnimeCatalogueSource,
        episodeData: EpisodeData?,
    ): String {
        if (episodeData == null) {
            throw IllegalArgumentException("episodeData is required for getEpisodeUrl")
        }
        if (source !is AnimeHttpSource) {
            throw IllegalArgumentException("Source must be AnimeHttpSource for getEpisodeUrl")
        }
        return source.getEpisodeUrl(episodeData.toSEpisode())
    }

    private fun invokeGetVideoList(
        source: AnimeCatalogueSource,
        episodeData: EpisodeData?,
    ): List<Video> {
        if (episodeData == null) {
            throw IllegalArgumentException("episodeData is required for getVideoList")
        }

        if (source !is AnimeHttpSource) {
            throw IllegalArgumentException("Source must be AnimeHttpSource for getVideoList")
        }

        return runBlocking {
            val videos = source.getVideoList(episodeData.toSEpisode())
            videos
        }
    }

    private fun MangaData.toSManga(source: Source): SManga =
        SManga.create().also { manga ->
            manga.url = url ?: ""
            manga.title = title ?: ""
            manga.artist = artist
            manga.author = author
            manga.description = description
            manga.genre = genre
            manga.status = status ?: 0
            manga.thumbnail_url = thumbnail_url
            manga.initialized = initialized ?: false
            MihonMetadataCache.restore(source, manga)
        }

    private fun ChapterData.toSChapter(source: Source): SChapter =
        SChapter.create().also { chapter ->
            chapter.url = url ?: ""
            chapter.name = name ?: ""
            chapter.date_upload = date_upload ?: 0L
            chapter.chapter_number = chapter_number ?: 0f
            chapter.scanlator = scanlator
            MihonMetadataCache.restore(source, chapter)
        }

    private fun AnimeData.toSAnime(): SAnime =
        SAnime.create().also { anime ->
            anime.url = url ?: ""
            anime.title = title ?: ""
            anime.artist = artist
            anime.author = author
            anime.description = description
            anime.genre = genre
            anime.status = status ?: 0
            anime.thumbnail_url = thumbnail_url
            anime.initialized = initialized ?: false
        }

    private fun EpisodeData.toSEpisode(): SEpisode =
        SEpisode.create().also { episode ->
            episode.url = url ?: ""
            episode.name = name ?: ""
            episode.date_upload = date_upload ?: 0L
            episode.episode_number = episode_number ?: 0f
            episode.scanlator = scanlator
        }

    private fun invokePreferencesAnime(source: AnimeCatalogueSource): MutableList<Map<String, Any>> {
        val preferences = mutableListOf<Map<String, Any>>()
        if (source !is ConfigurableAnimeSource) {
            return preferences
        }

        val screen = PreferenceScreen(context)
        val sourceId = (source as eu.kanade.tachiyomi.animesource.AnimeSource).id
        val prefs = context.getSharedPreferences("source_$sourceId", 0)
        screen.setSharedPreferences(prefs)

        (source as ConfigurableAnimeSource).setupPreferenceScreen(screen)

        processPreferences(screen, preferences)

        return preferences
    }

    private fun invokePreferencesManga(source: Source): MutableList<Map<String, Any>> {
        val preferences = mutableListOf<Map<String, Any>>()
        if (source !is eu.kanade.tachiyomi.source.ConfigurableSource) {
            return preferences
        }

        val screen = PreferenceScreen(context)
        val sourceId = source.id
        val prefs = context.getSharedPreferences("source_$sourceId", 0)
        screen.setSharedPreferences(prefs)

        (source as eu.kanade.tachiyomi.source.ConfigurableSource).setupPreferenceScreen(screen)

        processPreferences(screen, preferences)

        return preferences
    }

    private fun invokeSetPreferenceAnime(
        source: AnimeCatalogueSource,
        data: DataBody,
    ): MutableList<Map<String, Any>> {
        if (source !is ConfigurableAnimeSource) return mutableListOf()
        return invokeSetPreference(source.id, data, source::setupPreferenceScreen)
    }

    private fun invokeSetPreferenceManga(
        source: Source,
        data: DataBody,
    ): MutableList<Map<String, Any>> {
        if (source !is eu.kanade.tachiyomi.source.ConfigurableSource) return mutableListOf()
        return invokeSetPreference(source.id, data, source::setupPreferenceScreen)
    }

    private fun invokeSetPreference(
        sourceId: Long,
        data: DataBody,
        setup: (PreferenceScreen) -> Unit,
    ): MutableList<Map<String, Any>> {
        val screen = PreferenceScreen(context)
        val prefs = context.getSharedPreferences("source_$sourceId", 0)
        screen.setSharedPreferences(prefs)
        setup(screen)

        val changedKey = bridgeContext(data)["changedPreferenceKey"]?.toString()
        val changedData = data.preferences?.firstOrNull { it["key"] == changedKey }
        val preference =
            changedKey?.let { key ->
                screen.preferences.firstOrNull { it.key == key }
            }
        val changedValue = changedData?.let(::preferenceValue)
        if (preference != null && changedValue != null) {
            applyPreferenceChange(preference, changedValue)
        }

        val preferences = mutableListOf<Map<String, Any>>()
        processPreferences(screen, preferences)
        return preferences
    }

    internal fun applyPreferenceChange(
        preference: Preference,
        changedValue: Any,
    ) {
        // AndroidX asks the listener first. A false result can mean the
        // listener normalized and persisted the value itself.
        if (preference.callChangeListener(changedValue)) {
            preference.saveNewValue(changedValue)
        }
    }

    private fun preferenceValue(data: Map<String, Any>): Any? =
        when {
            data.containsKey("checkBoxPreference") ->
                (data["checkBoxPreference"] as? Map<*, *>)?.get("value")
            data.containsKey("switchPreferenceCompat") ->
                (data["switchPreferenceCompat"] as? Map<*, *>)?.get("value")
            data.containsKey("editTextPreference") ->
                (data["editTextPreference"] as? Map<*, *>)?.get("value")
            data.containsKey("listPreference") -> {
                val list = data["listPreference"] as? Map<*, *>
                val index = list?.get("valueIndex") as? Int
                val values = list?.get("entryValues") as? List<*>
                if (index != null && values != null && index in values.indices) values[index] else null
            }
            data.containsKey("multiSelectListPreference") ->
                ((data["multiSelectListPreference"] as? Map<*, *>)?.get("values") as? List<*>)?.toSet()
            else -> null
        }

    private fun processPreferences(
        screen: PreferenceScreen,
        preferences: MutableList<Map<String, Any>>,
    ) {
        for (i in 0 until screen.preferences.size) {
            val preference = screen.preferences[i]
            when (preference) {
                is CheckBoxPreference -> {
                    preferences.add(
                        mapOf(
                            "key" to preference.key,
                            "checkBoxPreference" to
                                mapOf(
                                    "title" to preference.title,
                                    "summary" to (preference.summary ?: ""),
                                    "value" to preference.currentValue,
                                ),
                        ),
                    )
                }
                is SwitchPreferenceCompat -> {
                    preferences.add(
                        mapOf(
                            "key" to preference.key,
                            "switchPreferenceCompat" to
                                mapOf(
                                    "title" to preference.title,
                                    "summary" to (preference.summary ?: ""),
                                    "value" to preference.currentValue,
                                ),
                        ),
                    )
                }
                is EditTextPreference -> {
                    preferences.add(
                        mapOf(
                            "key" to preference.key,
                            "editTextPreference" to
                                mapOf(
                                    "title" to preference.title,
                                    "summary" to (preference.summary ?: ""),
                                    "value" to preference.currentValue,
                                    "text" to preference.currentValue,
                                    "dialogMessage" to preference.getDialogMessage(),
                                    "dialogTitle" to preference.getDialogTitle(),
                                ),
                        ),
                    )
                }
                is ListPreference -> {
                    preferences.add(
                        mapOf(
                            "key" to preference.key,
                            "listPreference" to
                                mapOf(
                                    "title" to preference.title,
                                    "summary" to (preference.summary ?: ""),
                                    "valueIndex" to preference.findIndexOfValue(preference.currentValue.toString()),
                                    "entries" to preference.entries,
                                    "entryValues" to preference.entryValues,
                                ),
                        ),
                    )
                }
                is MultiSelectListPreference -> {
                    preferences.add(
                        mapOf(
                            "key" to preference.key,
                            "multiSelectListPreference" to
                                mapOf(
                                    "title" to preference.title,
                                    "summary" to (preference.summary ?: ""),
                                    "values" to preference.currentValue,
                                    "entries" to preference.entries,
                                    "entryValues" to preference.entryValues,
                                ),
                        ),
                    )
                }
            }
        }
    }

    fun applyPreferences(
        data: DataBody,
        source: Any,
        skipPreferenceKey: String? = null,
    ) {
        val preferences = data.preferences ?: return
        val sourceId =
            when (source) {
                is eu.kanade.tachiyomi.source.Source -> source.id
                is eu.kanade.tachiyomi.animesource.AnimeSource -> source.id
                else -> throw IllegalArgumentException("Unknown source type: ${source.javaClass}")
            }
        val prefs = context.getSharedPreferences("source_$sourceId", 0)
        val editor = prefs.edit()
        for (prefMap in preferences) {
            val rawKey = prefMap["key"] as? String ?: continue
            if (rawKey == skipPreferenceKey) continue
            // Java Preferences has 80 char limit for keys, hash long keys
            val key =
                if (rawKey.length > 80) {
                    val hash =
                        java.security.MessageDigest
                            .getInstance("SHA-256")
                            .digest(rawKey.toByteArray())
                            .joinToString("") { "%02x".format(it) }
                            .take(64)
                    "hash_$hash"
                } else {
                    rawKey
                }
            // The app sends its persisted preference snapshot on every bridge
            // request. Use it to initialize a fresh JVM preference store, but
            // do not let an older snapshot overwrite a value that the source
            // has already normalized and persisted itself.
            if (prefs.contains(key)) continue
            when {
                prefMap.containsKey("checkBoxPreference") -> {
                    val checkBox = prefMap["checkBoxPreference"] as? Map<*, *>
                    val value = checkBox?.get("value") as? Boolean
                    if (value != null) {
                        editor.putBoolean(key, value)
                    }
                }
                prefMap.containsKey("switchPreferenceCompat") -> {
                    val switch = prefMap["switchPreferenceCompat"] as? Map<*, *>
                    val value = switch?.get("value") as? Boolean
                    if (value != null) {
                        editor.putBoolean(key, value)
                    }
                }
                prefMap.containsKey("editTextPreference") -> {
                    val editText = prefMap["editTextPreference"] as? Map<*, *>
                    val value = editText?.get("value") as? String
                    if (value != null) {
                        editor.putString(key, value)
                    }
                }
                prefMap.containsKey("listPreference") -> {
                    val list = prefMap["listPreference"] as? Map<*, *>
                    val valueIndex = list?.get("valueIndex") as? Int
                    val entryValues = list?.get("entryValues") as? List<String>
                    if (valueIndex != null && entryValues != null && valueIndex in entryValues.indices) {
                        editor.putString(key, entryValues[valueIndex])
                    }
                }
                prefMap.containsKey("multiSelectListPreference") -> {
                    val multiList = prefMap["multiSelectListPreference"] as? Map<*, *>
                    val values = multiList?.get("values") as? List<String>
                    if (values != null) {
                        editor.putStringSet(key, values.toSet())
                    }
                }
            }
        }
        editor.apply()
    }

    private fun convertFilterList(
        originalFilters: FilterList,
        jFilters: List<JFilterList>,
    ): FilterList {
        // Apply the filter values from jFilters to the original filters
        val convertedFilters =
            originalFilters.map { filter ->
                when (filter) {
                    is Filter.Select<*> -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null) {
                            val state = jFilter.stateInt
                            if (state != null) {
                                filter.state = state
                            }
                        }
                        filter
                    }
                    is Filter.CheckBox -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null &&
                            jFilter.stateList != null &&
                            jFilter.stateList.isNotEmpty() &&
                            jFilter.stateList[0].stateBoolean is Boolean
                        ) {
                            filter.state = jFilter.stateList[0].stateBoolean as Boolean
                        }
                        filter
                    }
                    is Filter.TriState -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null && jFilter.stateInt is Int) {
                            filter.state = jFilter.stateInt
                        }
                        filter
                    }
                    is Filter.Text -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null && jFilter.stateString is String) {
                            filter.state = jFilter.stateString
                        }
                        filter
                    }
                    is Filter.Group<*> -> {
                        val groupFilter = filter as Filter.Group<Filter<*>>
                        val jGroup = jFilters.find { it.name == groupFilter.name }
                        if (jGroup != null) {
                            val subJFilters = jGroup.stateList
                            for (state in groupFilter.state) {
                                val jSubFilter = subJFilters?.find { it.name == state.name }
                                val dataGroup = jSubFilter
                                if (dataGroup == null) {
                                    continue
                                }
                                if (state is Filter.CheckBox) {
                                    val checkBox = state
                                    checkBox.state = dataGroup.stateBoolean ?: false
                                }
                                if (state is Filter.TriState) {
                                    val checkBox = state
                                    checkBox.state = dataGroup.stateInt ?: 0
                                }
                                if (state is Filter.Select<*>) {
                                    val select = state
                                    select.state = dataGroup.stateInt ?: 0
                                }
                                if (state is Filter.Text) {
                                    val text = state
                                    text.state = dataGroup.name ?: ""
                                }
                            }
                        }
                        filter
                    }
                    is Filter.Sort -> {
                        val jSort = jFilters.find { it.name == filter.name }
                        if (jSort != null) {
                            val dataSort = jSort.stateSort
                            if (dataSort != null && dataSort.index != null && dataSort.ascending != null) {
                                filter.state = Filter.Sort.Selection(dataSort.index, dataSort.ascending)
                            }
                        }
                        filter
                    }
                    else -> filter
                }
            }
        return FilterList(convertedFilters)
    }

    private fun convertAnimeFilterList(
        originalFilters: AnimeFilterList,
        jFilters: List<JFilterList>,
    ): AnimeFilterList {
        // Apply the filter values from jFilters to the original filters
        val convertedFilters =
            originalFilters.map { filter ->
                when (filter) {
                    is AnimeFilter.Select<*> -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null) {
                            val state = jFilter.stateInt as? Int
                            if (state != null) {
                                filter.state = state
                            }
                        }
                        filter
                    }
                    is AnimeFilter.CheckBox -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null &&
                            jFilter.stateList != null &&
                            jFilter.stateList.isNotEmpty() &&
                            jFilter.stateList[0].stateBoolean is Boolean
                        ) {
                            filter.state = jFilter.stateList[0].stateBoolean as Boolean
                        }
                        filter
                    }
                    is AnimeFilter.TriState -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null && jFilter.stateInt is Int) {
                            filter.state = jFilter.stateInt as Int
                        }
                        filter
                    }
                    is AnimeFilter.Text -> {
                        val jFilter = jFilters.find { it.name == filter.name }
                        if (jFilter != null && jFilter.stateString is String) {
                            filter.state = jFilter.stateString
                        }
                        filter
                    }
                    is AnimeFilter.Group<*> -> {
                        val groupFilter = filter as AnimeFilter.Group<AnimeFilter<*>>
                        val jGroup = jFilters.find { it.name == groupFilter.name }
                        if (jGroup != null) {
                            val subJFilters = jGroup.stateList
                            for (state in groupFilter.state) {
                                val jSubFilter = subJFilters?.find { it.name == state.name }
                                val dataGroup = jSubFilter
                                if (dataGroup == null) {
                                    continue
                                }
                                if (state is AnimeFilter.CheckBox) {
                                    val checkBox = state
                                    checkBox.state = dataGroup.stateBoolean ?: false
                                }
                                if (state is AnimeFilter.TriState) {
                                    val checkBox = state
                                    checkBox.state = dataGroup.stateInt ?: 0
                                }
                                if (state is AnimeFilter.Select<*>) {
                                    val select = state
                                    select.state = dataGroup.stateInt ?: 0
                                }
                                if (state is AnimeFilter.Text) {
                                    val text = state
                                    text.state = dataGroup.name ?: ""
                                }
                            }
                        }
                        filter
                    }
                    is AnimeFilter.Sort -> {
                        val jSort = jFilters.find { it.name == filter.name }
                        if (jSort != null) {
                            val dataSort = jSort.stateSort
                            if (dataSort != null && dataSort.index != null && dataSort.ascending != null) {
                                filter.state =
                                    AnimeFilter.Sort
                                        .Selection(dataSort.index, dataSort.ascending)
                            }
                        }
                        filter
                    }
                    else -> filter
                }
            }
        return AnimeFilterList(convertedFilters)
    }
}
