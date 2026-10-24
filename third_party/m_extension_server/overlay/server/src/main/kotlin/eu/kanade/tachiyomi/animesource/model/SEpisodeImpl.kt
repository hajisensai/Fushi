@file:Suppress("ktlint:standard:property-naming")

package eu.kanade.tachiyomi.animesource.model

import kotlinx.serialization.json.JsonObject

class SEpisodeImpl : SEpisode {
    override lateinit var url: String

    override lateinit var name: String

    override var date_upload: Long = 0

    override var episode_number: Float = -1f

    override var fillermark: Boolean = false

    override var scanlator: String? = null

    override var summary: String? = null

    override var preview_url: String? = null

    // See SAnimeImpl.memo: not part of the java.io.Serializable form.
    @Transient
    private var memoValue: JsonObject? = null

    override var memo: JsonObject
        get() = memoValue ?: Video.EMPTY_MEMO
        set(value) {
            memoValue = value
        }
}
