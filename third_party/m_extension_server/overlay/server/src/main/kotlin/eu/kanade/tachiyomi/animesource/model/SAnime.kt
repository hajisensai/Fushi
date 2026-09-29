@file:Suppress("ktlint:standard:property-naming")

package eu.kanade.tachiyomi.animesource.model

import java.io.Serializable

/**
 * Hibiki host ABI: the extensions-lib 16 property set (`background_url`,
 * `fetch_type`, `season_number` on top of the lib-14 fields). Extensions built
 * against the yuzono / Anikku lib assign these from their parsers, so a host that
 * lacks the accessors fails with NoSuchMethodError on the first details parse.
 */
interface SAnime : Serializable {
    var url: String

    var title: String

    var artist: String?

    var author: String?

    var description: String?

    var genre: String?

    var status: Int

    var thumbnail_url: String?

    /** @since extensions-lib 16 */
    var background_url: String?

    var update_strategy: AnimeUpdateStrategy

    /** @since extensions-lib 16 */
    var fetch_type: FetchType

    /** @since extensions-lib 16 */
    var season_number: Double

    var initialized: Boolean

    fun copyFrom(other: SAnime) {
        title = other.title

        if (other.author != null) {
            author = other.author
        }

        if (other.artist != null) {
            artist = other.artist
        }

        if (other.description != null) {
            description = other.description
        }

        if (other.genre != null) {
            genre = other.genre
        }

        if (other.thumbnail_url != null) {
            thumbnail_url = other.thumbnail_url
        }

        if (other.background_url != null) {
            background_url = other.background_url
        }

        status = other.status

        update_strategy = other.update_strategy

        fetch_type = other.fetch_type

        season_number = other.season_number

        if (!initialized) {
            initialized = other.initialized
        }
    }

    companion object {
        const val UNKNOWN = 0
        const val ONGOING = 1
        const val COMPLETED = 2
        const val LICENSED = 3
        const val PUBLISHING_FINISHED = 4
        const val CANCELLED = 5
        const val ON_HIATUS = 6

        fun create(): SAnime = SAnimeImpl()
    }
}
