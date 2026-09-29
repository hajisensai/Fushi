package app.fushi.reader.mihon

import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga

internal fun SManga.toBridgeMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "title" to title,
    "thumbnail_url" to thumbnail_url,
    "artist" to artist,
    "author" to author,
    "description" to description,
    "genre" to genre,
    "status" to status,
    "initialized" to initialized,
)

/**
 * 把详情解析结果合进已知条目。
 *
 * Mihon 的 `mangaDetailsParse` 返回的是**增量**，不是完整条目：它
 * `SManga.create()` 一个新对象，只填元数据，**从不回填 `url`**——因为
 * `url` 是条目身份，上游官方 app 只把元数据 merge 回已存条目，永远不读
 * 返回值的 `url`。而 `SMangaImpl.url` / `title` 是 `lateinit var`，所以谁把
 * 这个增量对象当完整条目读，谁就吃
 * `UninitializedPropertyAccessException`（BUG-1767：漫画列表能开、点进去必报
 * RUNTIME_FAILURE）。
 *
 * 所以身份永远取自入参，只有元数据走“新值覆盖旧值”。
 */
internal fun SManga.mergedWithDetails(update: SManga): SManga = SManga.create().apply {
    val base = this@mergedWithDetails
    url = base.url
    title = lateinitOrNull { update.title }?.takeIf { value -> value.isNotEmpty() }
        ?: base.title
    thumbnail_url = update.thumbnail_url ?: base.thumbnail_url
    artist = update.artist ?: base.artist
    author = update.author ?: base.author
    description = update.description ?: base.description
    genre = update.genre ?: base.genre
    status = if (update.status != SManga.UNKNOWN) update.status else base.status
    initialized = update.initialized || base.initialized
}

/**
 * 读一个可能未初始化的 `lateinit` 属性。
 *
 * 类外部拿不到 `::title.isInitialized`，而第三方扩展能否赋值不在宕主
 * 控制范围内，因此只能捕获。只接 [UninitializedPropertyAccessException]，
 * 其他异常照旧往上抛——这里存在为了识别“没赋值”这一个信号，
 * 不是为了吞错。
 */
private inline fun <T> lateinitOrNull(read: () -> T): T? = try {
    read()
} catch (_: UninitializedPropertyAccessException) {
    null
}

internal fun mangaFromBridge(value: Map<String, Any?>): SManga = SManga.create().apply {
    url = value["url"]?.toString().orEmpty()
    title = value["title"]?.toString().orEmpty()
    thumbnail_url = value["thumbnail_url"]?.toString()
    artist = value["artist"]?.toString()
    author = value["author"]?.toString()
    description = value["description"]?.toString()
    genre = value["genre"]?.toString()
    status = (value["status"] as? Number)?.toInt() ?: SManga.UNKNOWN
    initialized = value["initialized"] == true
}

internal fun SChapter.toBridgeMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "name" to name,
    "date_upload" to date_upload,
    "chapter_number" to chapter_number.toDouble(),
    "scanlator" to scanlator,
)

internal fun chapterFromBridge(value: Map<String, Any?>): SChapter = SChapter.create().apply {
    url = value["url"]?.toString().orEmpty()
    name = value["name"]?.toString().orEmpty()
    date_upload = (value["date_upload"] as? Number)?.toLong() ?: 0L
    chapter_number = (value["chapter_number"] as? Number)?.toFloat() ?: 0f
    scanlator = value["scanlator"]?.toString()
}

internal fun Page.toBridgeMap(): Map<String, Any?> = mapOf(
    "index" to index,
    "url" to url,
    "imageUrl" to imageUrl,
)

internal fun filterListToBridge(filters: FilterList): List<Map<String, Any?>> =
    filters.map { filter -> filterToBridge(filter) }

private fun filterToBridge(filter: Filter<*>): Map<String, Any?> {
    val type = when (filter) {
        is Filter.Header -> "header"
        is Filter.Separator -> "separator"
        is Filter.Select<*> -> "select"
        is Filter.Text -> "text"
        is Filter.CheckBox -> "checkBox"
        is Filter.TriState -> "triState"
        is Filter.Group<*> -> "group"
        is Filter.Sort -> "sort"
    }
    return buildMap {
        put("name", filter.name)
        put("type", type)
        when (filter) {
            is Filter.Select<*> -> {
                put("state", filter.state)
                put("values", filter.values.map { item -> item.toString() })
            }
            is Filter.Text -> put("state", filter.state)
            is Filter.CheckBox -> put("state", filter.state)
            is Filter.TriState -> put("state", filter.state)
            is Filter.Group<*> -> put(
                "children",
                filter.state.filterIsInstance<Filter<*>>().map { child -> filterToBridge(child) },
            )
            is Filter.Sort -> {
                put("values", filter.values.toList())
                put(
                    "state",
                    mapOf(
                        "index" to (filter.state?.index ?: 0),
                        "ascending" to (filter.state?.ascending ?: true),
                    ),
                )
            }
            else -> Unit
        }
    }
}

internal fun applyBridgeFilters(
    filters: FilterList,
    values: List<Map<String, Any?>>,
): FilterList {
    filters.forEach { filter ->
        val value = values.firstOrNull { item -> item["name"]?.toString() == filter.name }
            ?: return@forEach
        applyBridgeFilter(filter, value)
    }
    return filters
}

@Suppress("UNCHECKED_CAST")
private fun applyBridgeFilter(filter: Filter<*>, value: Map<String, Any?>) {
    when (filter) {
        is Filter.Select<*> -> filter.state = (value["stateInt"] as? Number)?.toInt()
            ?: (value["state"] as? Number)?.toInt()
            ?: filter.state
        is Filter.Text -> filter.state = value["stateString"]?.toString()
            ?: value["state"]?.toString()
            ?: filter.state
        is Filter.CheckBox -> {
            val first = (value["stateList"] as? List<*>)
                ?.firstOrNull() as? Map<*, *>
            filter.state = first?.get("stateBoolean") as? Boolean
                ?: value["state"] as? Boolean
                ?: filter.state
        }
        is Filter.TriState -> filter.state = (value["stateInt"] as? Number)?.toInt()
            ?: (value["state"] as? Number)?.toInt()
            ?: filter.state
        is Filter.Group<*> -> {
            val children = (value["stateList"] as? List<*>)
                ?.filterIsInstance<Map<String, Any?>>()
                ?: (value["children"] as? List<*>)
                    ?.filterIsInstance<Map<String, Any?>>()
                ?: emptyList()
            (filter.state as List<*>).filterIsInstance<Filter<*>>().forEach { child ->
                val childValue = children.firstOrNull {
                    item -> item["name"]?.toString() == child.name
                } ?: return@forEach
                applyBridgeFilter(child, childValue)
            }
        }
        is Filter.Sort -> {
            val state = value["stateSort"] as? Map<*, *>
                ?: value["state"] as? Map<*, *>
            val index = (state?.get("index") as? Number)?.toInt()
                ?: (value["stateInt"] as? Number)?.toInt()
                ?: 0
            val ascending = state?.get("ascending") as? Boolean ?: true
            filter.state = Filter.Sort.Selection(index, ascending)
        }
        else -> Unit
    }
}

// ── Aniyomi（视频）模型桥接 ──────────────────────────────────────────
// 与上面的漫画桥接逐字段同构：上游两套模型本就是复制的，wire 形状与桌面 sidecar
// 的 `JAnime` / `JEpisode` / `Video.toBridgeMap()` 一致。

internal fun SAnime.toBridgeMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "title" to title,
    "thumbnail_url" to thumbnail_url,
    "artist" to artist,
    "author" to author,
    "description" to description,
    "genre" to genre,
    "status" to status,
    "initialized" to initialized,
)

/** 同 [SManga.mergedWithDetails]：详情是增量，身份 `url` 永远取自入参。 */
internal fun SAnime.mergedWithDetails(update: SAnime): SAnime = SAnime.create().apply {
    val base = this@mergedWithDetails
    url = base.url
    title = lateinitOrNull { update.title }?.takeIf { value -> value.isNotEmpty() }
        ?: base.title
    thumbnail_url = update.thumbnail_url ?: base.thumbnail_url
    artist = update.artist ?: base.artist
    author = update.author ?: base.author
    description = update.description ?: base.description
    genre = update.genre ?: base.genre
    status = if (update.status != SAnime.UNKNOWN) update.status else base.status
    initialized = update.initialized || base.initialized
}

internal fun animeFromBridge(value: Map<String, Any?>): SAnime = SAnime.create().apply {
    url = value["url"]?.toString().orEmpty()
    title = value["title"]?.toString().orEmpty()
    thumbnail_url = value["thumbnail_url"]?.toString()
    artist = value["artist"]?.toString()
    author = value["author"]?.toString()
    description = value["description"]?.toString()
    genre = value["genre"]?.toString()
    status = (value["status"] as? Number)?.toInt() ?: SAnime.UNKNOWN
    initialized = value["initialized"] == true
}

internal fun SEpisode.toBridgeMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "name" to name,
    "date_upload" to date_upload,
    "episode_number" to episode_number.toDouble(),
    "scanlator" to scanlator,
)

internal fun episodeFromBridge(value: Map<String, Any?>): SEpisode = SEpisode.create().apply {
    url = value["url"]?.toString().orEmpty()
    name = value["name"]?.toString().orEmpty()
    date_upload = (value["date_upload"] as? Number)?.toLong() ?: 0L
    episode_number = (value["episode_number"] as? Number)?.toFloat() ?: 0f
    scanlator = value["scanlator"]?.toString()
}

/**
 * 一条可播候选的通道形状，与桌面 sidecar `DalvikHandler.Video.toBridgeMap` 逐字段
 * 相同：`url` / `quality` / `videoUrl` 是宿主已在解码的 lib 14 名字，
 * `videoTitle` / `resolution` / `bitrate` / `preferred` 是 lib 16 的选流字段；
 * okhttp `Headers` 摊成 map。lib 16 的过时构造把空 `videoUrl` 存成字符串 "null"，
 * 通道保持 lib 14 语义（null = 未解析）。
 */
internal fun Video.toBridgeMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "quality" to quality,
    "videoUrl" to videoUrl.takeUnless { isVideoUrlUnresolved },
    "videoTitle" to videoTitle,
    "resolution" to resolution,
    "bitrate" to bitrate,
    "preferred" to preferred,
    "headers" to headers?.let { headers ->
        (0 until headers.size).associate { index -> headers.name(index) to headers.value(index) }
    },
    "subtitleTracks" to subtitleTracks.map { track -> mapOf("url" to track.url, "lang" to track.lang) },
    "audioTracks" to audioTracks.map { track -> mapOf("url" to track.url, "lang" to track.lang) },
    "mpvArgs" to mpvArgs.map { (key, value) -> mapOf("key" to key, "value" to value) },
)

internal fun animeFilterListToBridge(filters: AnimeFilterList): List<Map<String, Any?>> =
    filters.map { filter -> animeFilterToBridge(filter) }

private fun animeFilterToBridge(filter: AnimeFilter<*>): Map<String, Any?> {
    val type = when (filter) {
        is AnimeFilter.Header -> "header"
        is AnimeFilter.Separator -> "separator"
        is AnimeFilter.Select<*> -> "select"
        is AnimeFilter.Text -> "text"
        is AnimeFilter.CheckBox -> "checkBox"
        is AnimeFilter.TriState -> "triState"
        is AnimeFilter.Group<*> -> "group"
        is AnimeFilter.Sort -> "sort"
    }
    return buildMap {
        put("name", filter.name)
        put("type", type)
        when (filter) {
            is AnimeFilter.Select<*> -> {
                put("state", filter.state)
                put("values", filter.values.map { item -> item.toString() })
            }
            is AnimeFilter.Text -> put("state", filter.state)
            is AnimeFilter.CheckBox -> put("state", filter.state)
            is AnimeFilter.TriState -> put("state", filter.state)
            is AnimeFilter.Group<*> -> put(
                "children",
                filter.state.filterIsInstance<AnimeFilter<*>>().map { child -> animeFilterToBridge(child) },
            )
            is AnimeFilter.Sort -> {
                put("values", filter.values.toList())
                put(
                    "state",
                    mapOf(
                        "index" to (filter.state?.index ?: 0),
                        "ascending" to (filter.state?.ascending ?: true),
                    ),
                )
            }
            else -> Unit
        }
    }
}

internal fun applyBridgeAnimeFilters(
    filters: AnimeFilterList,
    values: List<Map<String, Any?>>,
): AnimeFilterList {
    filters.forEach { filter ->
        val value = values.firstOrNull { item -> item["name"]?.toString() == filter.name }
            ?: return@forEach
        applyBridgeAnimeFilter(filter, value)
    }
    return filters
}

@Suppress("UNCHECKED_CAST")
private fun applyBridgeAnimeFilter(filter: AnimeFilter<*>, value: Map<String, Any?>) {
    when (filter) {
        is AnimeFilter.Select<*> -> filter.state = (value["stateInt"] as? Number)?.toInt()
            ?: (value["state"] as? Number)?.toInt()
            ?: filter.state
        is AnimeFilter.Text -> filter.state = value["stateString"]?.toString()
            ?: value["state"]?.toString()
            ?: filter.state
        is AnimeFilter.CheckBox -> {
            val first = (value["stateList"] as? List<*>)
                ?.firstOrNull() as? Map<*, *>
            filter.state = first?.get("stateBoolean") as? Boolean
                ?: value["state"] as? Boolean
                ?: filter.state
        }
        is AnimeFilter.TriState -> filter.state = (value["stateInt"] as? Number)?.toInt()
            ?: (value["state"] as? Number)?.toInt()
            ?: filter.state
        is AnimeFilter.Group<*> -> {
            val children = (value["stateList"] as? List<*>)
                ?.filterIsInstance<Map<String, Any?>>()
                ?: (value["children"] as? List<*>)
                    ?.filterIsInstance<Map<String, Any?>>()
                ?: emptyList()
            (filter.state as List<*>).filterIsInstance<AnimeFilter<*>>().forEach { child ->
                val childValue = children.firstOrNull {
                    item -> item["name"]?.toString() == child.name
                } ?: return@forEach
                applyBridgeAnimeFilter(child, childValue)
            }
        }
        is AnimeFilter.Sort -> {
            val state = value["stateSort"] as? Map<*, *>
                ?: value["state"] as? Map<*, *>
            val index = (state?.get("index") as? Number)?.toInt()
                ?: (value["stateInt"] as? Number)?.toInt()
                ?: 0
            val ascending = state?.get("ascending") as? Boolean ?: true
            filter.state = AnimeFilter.Sort.Selection(index, ascending)
        }
        else -> Unit
    }
}
