package eu.kanade.tachiyomi.animesource

import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.util.lang.awaitSingle
import rx.Observable

/**
 * Hibiki host ABI: lib 14 catalogue surface plus the Anikku/KMK related-anime
 * members (all defaulted; the host never calls them, they only have to link).
 */
interface AnimeCatalogueSource : AnimeSource {
    /**
     * An ISO 639-1 compliant language code (two letters in lower case).
     */
    override val lang: String

    /**
     * Whether the source has support for latest updates.
     */
    val supportsLatest: Boolean

    /**
     * Get a page with a list of anime.
     *
     * @since extensions-lib 14
     * @param page the page number to retrieve.
     */
    @Suppress("DEPRECATION")
    suspend fun getPopularAnime(page: Int): AnimesPage = fetchPopularAnime(page).awaitSingle()

    /**
     * Get a page with a list of anime.
     *
     * @since extensions-lib 14
     * @param page the page number to retrieve.
     * @param query the search query.
     * @param filters the list of filters to apply.
     */
    @Suppress("DEPRECATION")
    suspend fun getSearchAnime(
        page: Int,
        query: String,
        filters: AnimeFilterList,
    ): AnimesPage = fetchSearchAnime(page, query, filters).awaitSingle()

    /**
     * Get a page with a list of latest anime updates.
     *
     * @since extensions-lib 14
     * @param page the page number to retrieve.
     */
    @Suppress("DEPRECATION")
    suspend fun getLatestUpdates(page: Int): AnimesPage = fetchLatestUpdates(page).awaitSingle()

    /**
     * Returns the list of filters for the source.
     */
    fun getFilterList(): AnimeFilterList

    // KMK -->

    /**
     * Whether the source supports related-anime discovery at all.
     *
     * @since anikku/extensions-lib 15
     */
    val supportsRelatedAnimes: Boolean get() = false

    /**
     * Disable showing related animes by search for the source.
     *
     * @since anikku/extensions-lib 15
     */
    val disableRelatedAnimesBySearch: Boolean get() = false

    /**
     * Disable showing related animes for the source.
     *
     * @since anikku/extensions-lib 15
     */
    val disableRelatedAnimes: Boolean get() = false

    override suspend fun getRelatedAnimeList(
        anime: SAnime,
        exceptionHandler: (Throwable) -> Unit,
        pushResults: suspend (relatedAnime: Pair<String, List<SAnime>>, completed: Boolean) -> Unit,
    ) {
        pushResults(Pair("", emptyList()), true)
    }

    suspend fun getRelatedAnimeListByExtension(
        anime: SAnime,
        pushResults: suspend (relatedAnime: Pair<String, List<SAnime>>, completed: Boolean) -> Unit,
    ) {
        pushResults(Pair("", emptyList()), true)
    }

    suspend fun fetchRelatedAnimeList(anime: SAnime): List<SAnime> = throw UnsupportedOperationException("Unsupported!")

    fun String.stripKeywordForRelatedAnimes(): List<String> = listOf(this)

    suspend fun getRelatedAnimeListBySearch(
        anime: SAnime,
        pushResults: suspend (relatedAnime: Pair<String, List<SAnime>>, completed: Boolean) -> Unit,
    ) {
        pushResults(Pair("", emptyList()), true)
    }
    // KMK <--

    // Should be replaced as soon as Anime Extension reach 1.5
    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getPopularAnime"),
    )
    fun fetchPopularAnime(page: Int): Observable<AnimesPage>

    // Should be replaced as soon as Anime Extension reach 1.5
    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getSearchAnime"),
    )
    fun fetchSearchAnime(
        page: Int,
        query: String,
        filters: AnimeFilterList,
    ): Observable<AnimesPage>

    // Should be replaced as soon as Anime Extension reach 1.5
    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getLatestUpdates"),
    )
    fun fetchLatestUpdates(page: Int): Observable<AnimesPage>
}
