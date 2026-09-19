package eu.kanade.tachiyomi.animesource.model

/**
 * What an anime entry expands into: episodes directly, or a list of seasons
 * (each itself an [SAnime]) that in turn carry episodes.
 *
 * @since extensions-lib 16
 */
enum class FetchType {
    Seasons,
    Episodes,
}
