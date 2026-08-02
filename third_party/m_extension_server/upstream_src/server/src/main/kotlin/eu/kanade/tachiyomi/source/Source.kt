package eu.kanade.tachiyomi.source

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.util.lang.awaitSingle
import kotlinx.coroutines.async
import kotlinx.coroutines.supervisorScope
import rx.Observable

/**
 * A basic interface for creating a source. It could be an online source, a local source, etc.
 */
interface Source {
    /**
     * ID for the source. Must be unique.
     */
    val id: Long

    /**
     * Name of the source.
     */
    val name: String

    val lang: String
        get() = ""

    /**
     * Whether the source has support for latest updates.
     */
    val supportsLatest: Boolean
        get() = false

    /**
     * Returns the list of filters for the source.
     */
    fun getFilterList(): FilterList = FilterList()

    /**
     * Get a page with a list of manga.
     *
     * @since tachiyomix 1.6
     */
    suspend fun getPopularManga(page: Int): MangasPage = throw UnsupportedOperationException()

    /**
     * Get a page with a list of latest manga updates.
     *
     * @since tachiyomix 1.6
     */
    suspend fun getLatestUpdates(page: Int): MangasPage = throw UnsupportedOperationException()

    /**
     * Get a page with a list of manga matching [query] and [filters].
     *
     * @since tachiyomix 1.6
     */
    suspend fun getSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): MangasPage = throw UnsupportedOperationException()

    /**
     * Fetch updated manga details, chapters, or both.
     *
     * The default implementation preserves compatibility with pre-1.6 sources
     * that implement the split detail and chapter APIs.
     *
     * @since tachiyomix 1.6
     */
    suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate =
        supervisorScope {
            val updatedManga = if (fetchDetails) async { getMangaDetails(manga) } else null
            val updatedChapters = if (fetchChapters) async { getChapterList(manga) } else null
            SMangaUpdate(
                updatedManga?.await() ?: manga,
                updatedChapters?.await() ?: chapters,
            )
        }

    /**
     * Get the updated details for a manga.
     *
     * @since extensions-lib 1.5
     * @param manga the manga to update.
     * @return the updated manga.
     */
    @Suppress("DEPRECATION")
    suspend fun getMangaDetails(manga: SManga): SManga = fetchMangaDetails(manga).awaitSingle()

    /**
     * Get all the available chapters for a manga.
     *
     * @since extensions-lib 1.5
     * @param manga the manga to update.
     * @return the chapters for the manga.
     */
    @Suppress("DEPRECATION")
    suspend fun getChapterList(manga: SManga): List<SChapter> = fetchChapterList(manga).awaitSingle()

    /**
     * Get the list of pages a chapter has. Pages should be returned
     * in the expected order; the index is ignored.
     *
     * @since extensions-lib 1.5
     * @param chapter the chapter.
     * @return the pages for the chapter.
     */
    @Suppress("DEPRECATION")
    suspend fun getPageList(chapter: SChapter): List<Page> = fetchPageList(chapter).awaitSingle()

    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getMangaDetails"),
    )
    fun fetchMangaDetails(manga: SManga): Observable<SManga> = throw IllegalStateException("Not used")

    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getChapterList"),
    )
    fun fetchChapterList(manga: SManga): Observable<List<SChapter>> = throw IllegalStateException("Not used")

    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getPageList"),
    )
    fun fetchPageList(chapter: SChapter): Observable<List<Page>> = throw IllegalStateException("Not used")
}

// fun Source.icon(): Drawable? = Injekt.get<ExtensionManager>().getAppIconForSource(this)
