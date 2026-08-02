package mextensionserver.impl

import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.serialization.json.JsonObject

/**
 * Retains TachiyomiX 1.6 memo metadata across the bridge's stateless RPCs.
 *
 * Mangatan's current protocol sends manga and chapter URLs back to the bridge,
 * but not source-specific memo fields. Keeping those fields here lets sources
 * use metadata returned by catalogue and chapter-list calls as intended.
 */
internal object MihonMetadataCache {
    private const val MAX_ENTRIES = 8192

    private enum class Kind {
        MANGA,
        CHAPTER,
    }

    private class Key(
        val source: Source,
        val kind: Kind,
        val url: String,
    ) {
        override fun equals(other: Any?): Boolean =
            other is Key &&
                other.source === source &&
                other.kind == kind &&
                other.url == url

        override fun hashCode(): Int {
            var result = System.identityHashCode(source)
            result = 31 * result + kind.hashCode()
            result = 31 * result + url.hashCode()
            return result
        }
    }

    private val lock = Any()
    private val entries = LinkedHashMap<Key, JsonObject>(16, 0.75f, true)

    fun remember(
        source: Source,
        manga: SManga,
    ) {
        val url = runCatching { manga.url }.getOrNull()?.takeIf(String::isNotBlank) ?: return
        val memo = runCatching { manga.memo }.getOrNull() ?: return
        remember(Key(source, Kind.MANGA, url), memo)
    }

    fun remember(
        source: Source,
        chapter: SChapter,
    ) {
        val url = runCatching { chapter.url }.getOrNull()?.takeIf(String::isNotBlank) ?: return
        val memo = runCatching { chapter.memo }.getOrNull() ?: return
        remember(Key(source, Kind.CHAPTER, url), memo)
    }

    fun restore(
        source: Source,
        manga: SManga,
    ) {
        val url = runCatching { manga.url }.getOrNull()?.takeIf(String::isNotBlank) ?: return
        restore(Key(source, Kind.MANGA, url))?.let { memo ->
            runCatching { manga.memo = memo }
        }
    }

    fun restore(
        source: Source,
        chapter: SChapter,
    ) {
        val url = runCatching { chapter.url }.getOrNull()?.takeIf(String::isNotBlank) ?: return
        restore(Key(source, Kind.CHAPTER, url))?.let { memo ->
            runCatching { chapter.memo = memo }
        }
    }

    fun remove(source: Source) {
        synchronized(lock) {
            entries.keys.removeAll { it.source === source }
        }
    }

    fun clear() {
        synchronized(lock) {
            entries.clear()
        }
    }

    private fun remember(
        key: Key,
        memo: JsonObject,
    ) {
        synchronized(lock) {
            entries[key] = memo
            while (entries.size > MAX_ENTRIES) {
                entries.entries.iterator().run {
                    next()
                    remove()
                }
            }
        }
    }

    private fun restore(key: Key): JsonObject? =
        synchronized(lock) {
            entries[key]
        }
}
