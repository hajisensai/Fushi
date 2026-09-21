@file:Suppress("ktlint:standard:property-naming")

package eu.kanade.tachiyomi.animesource.model

import java.io.Serializable

/**
 * Hibiki host ABI: the extensions-lib 16 property set (`fillermark`, `summary`,
 * `preview_url` on top of the lib-14 fields). Episode parsers in the yuzono /
 * Anikku ecosystem assign `fillermark`, which on a lib-14 host is a
 * NoSuchMethodError at the first episode list -- the "cannot open the source"
 * symptom.
 */
interface SEpisode : Serializable {
    var url: String

    var name: String

    var date_upload: Long

    var episode_number: Float

    /** @since extensions-lib 16 */
    var fillermark: Boolean

    var scanlator: String?

    /** @since extensions-lib 16 */
    var summary: String?

    /** @since extensions-lib 16 */
    var preview_url: String?

    fun copyFrom(other: SEpisode) {
        name = other.name
        url = other.url
        date_upload = other.date_upload
        episode_number = other.episode_number
        fillermark = other.fillermark
        scanlator = other.scanlator
        summary = other.summary
        preview_url = other.preview_url
    }

    companion object {
        fun create(): SEpisode = SEpisodeImpl()
    }
}
