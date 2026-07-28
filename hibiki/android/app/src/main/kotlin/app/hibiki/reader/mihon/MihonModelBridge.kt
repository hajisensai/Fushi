package app.hibiki.reader.mihon

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
