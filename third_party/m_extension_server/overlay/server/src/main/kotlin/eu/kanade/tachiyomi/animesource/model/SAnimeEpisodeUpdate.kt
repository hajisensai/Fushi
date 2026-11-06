package eu.kanade.tachiyomi.animesource.model

/**
 * Result of the combined lib-17 `getAnimeEpisodeUpdate`: refreshed details and/or
 * the episode list.
 *
 * @since extensions-lib 17
 */
class SAnimeEpisodeUpdate(
    val anime: SAnime,
    val episodes: List<SEpisode>,
)
