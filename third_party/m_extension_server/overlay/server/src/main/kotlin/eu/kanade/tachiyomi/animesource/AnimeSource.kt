package eu.kanade.tachiyomi.animesource

import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.Hoster.Companion.toHosterList
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.util.lang.awaitSingle
import rx.Observable

/**
 * A basic interface for creating a source. It could be an online source, a local source, etc...
 *
 * Hibiki host ABI: the union of extensions-lib 14 (`getVideoList(episode)` and the
 * Rx `fetch*` shapes) and extensions-lib 16 (`getSeasonList`, `getHosterList`,
 * `getVideoList(hoster)`) plus the Anikku/KMK `getRelatedAnimeList` slot. Every
 * lib-16 member has a default body so a lib-14 extension that never heard of it
 * still loads; the defaults route the hoster API onto the legacy video list so the
 * host can drive both generations through one entry point.
 */
interface AnimeSource {
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
     * Get the updated details for a anime.
     *
     * @since extensions-lib 14
     * @param anime the anime to update.
     * @return the updated anime.
     */
    @Suppress("DEPRECATION")
    suspend fun getAnimeDetails(anime: SAnime): SAnime = fetchAnimeDetails(anime).awaitSingle()

    /**
     * Get all the available episodes for a anime.
     *
     * @since extensions-lib 14
     * @param anime the anime to update.
     * @return the episodes for the anime.
     */
    @Suppress("DEPRECATION")
    suspend fun getEpisodeList(anime: SAnime): List<SEpisode> = fetchEpisodeList(anime).awaitSingle()

    /**
     * Get all the available seasons for an anime.
     *
     * @since extensions-lib 16
     * @param anime the anime to fetch seasons for.
     * @return the anime list for the anime.
     */
    suspend fun getSeasonList(anime: SAnime): List<SAnime> = throw UnsupportedOperationException("Season list not supported")

    /**
     * Get the list of hosters for an episode. The first hoster in the list should be
     * the preferred hoster.
     *
     * lib 14 default: the legacy video list wrapped in a single [Hoster.NO_HOSTER_LIST]
     * hoster (exactly what Aniyomi's own compatibility shim does), so the host only
     * ever has to call this one method.
     *
     * @since extensions-lib 16
     * @param episode the episode.
     * @return the hosters for the episode.
     */
    suspend fun getHosterList(episode: SEpisode): List<Hoster> = getVideoList(episode).toHosterList()

    /**
     * Get the list of videos for a hoster.
     *
     * @since extensions-lib 16
     * @param hoster the hoster.
     * @return the videos for the hoster.
     */
    suspend fun getVideoList(hoster: Hoster): List<Video> =
        hoster.videoList ?: throw UnsupportedOperationException("Hoster video list not supported")

    /**
     * Get the list of videos a episode has. Videos should be returned
     * in the expected order; the index is ignored.
     *
     * @since extensions-lib 14
     * @param episode the episode.
     * @return the videos for the episode.
     */
    @Suppress("DEPRECATION")
    suspend fun getVideoList(episode: SEpisode): List<Video> = fetchVideoList(episode).awaitSingle()

    // KMK -->

    /**
     * Get all the available related animes for an anime.
     *
     * The host never asks for related entries; the slot exists so Anikku-flavoured
     * extensions that override it link.
     *
     * @since anikku/extensions-lib 15
     */
    suspend fun getRelatedAnimeList(
        anime: SAnime,
        exceptionHandler: (Throwable) -> Unit,
        pushResults: suspend (relatedAnime: Pair<String, List<SAnime>>, completed: Boolean) -> Unit,
    ) {
        pushResults(Pair("", emptyList()), true)
    }
    // KMK <--

    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getAnimeDetails"),
    )
    fun fetchAnimeDetails(anime: SAnime): Observable<SAnime> = throw IllegalStateException("Not used")

    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getEpisodeList"),
    )
    fun fetchEpisodeList(anime: SAnime): Observable<List<SEpisode>> = throw IllegalStateException("Not used")

    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getVideoList"),
    )
    fun fetchVideoList(episode: SEpisode): Observable<List<Video>> = throw IllegalStateException("Not used")
}
