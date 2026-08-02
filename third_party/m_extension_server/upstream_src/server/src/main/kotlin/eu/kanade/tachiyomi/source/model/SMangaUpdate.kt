package eu.kanade.tachiyomi.source.model

/**
 * Manga metadata and chapters returned by TachiyomiX's combined update API.
 */
class SMangaUpdate(
    val manga: SManga,
    val chapters: List<SChapter>,
)
