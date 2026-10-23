package eu.kanade.tachiyomi.animesource.model

/**
 * Result of the combined lib-17 `getAnimeSeasonUpdate`: refreshed details and/or
 * the season list.
 *
 * @since extensions-lib 17
 */
class SAnimeSeasonUpdate(
    val anime: SAnime,
    val seasons: List<SAnime>,
)
