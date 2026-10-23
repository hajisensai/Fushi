package eu.kanade.tachiyomi.animesource.model

/**
 * A named group of anime related to one entry (extensions-lib 17).
 *
 * The host never asks for related entries; the class exists so lib-17 extensions
 * that build it inside `getRelatedAnimeList` link.
 *
 * @since extensions-lib 17
 * @param name label shown above the row, e.g. "Sequels", "Recommended".
 * @param animes the related entries, in display order.
 */
class AnimeRelation(
    val name: String,
    val animes: List<SAnime>,
)
