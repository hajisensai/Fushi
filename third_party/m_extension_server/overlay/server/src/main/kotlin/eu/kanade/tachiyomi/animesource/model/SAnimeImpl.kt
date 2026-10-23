@file:Suppress("ktlint:standard:property-naming")

package eu.kanade.tachiyomi.animesource.model

import kotlinx.serialization.json.JsonObject

class SAnimeImpl : SAnime {
    override lateinit var url: String

    override lateinit var title: String

    override var artist: String? = null

    override var author: String? = null

    override var description: String? = null

    override var genre: String? = null

    override var status: Int = 0

    override var thumbnail_url: String? = null

    override var background_url: String? = null

    override var update_strategy: AnimeUpdateStrategy = AnimeUpdateStrategy.ALWAYS_UPDATE

    override var fetch_type: FetchType = FetchType.Episodes

    override var season_number: Double = -1.0

    // `JsonObject` is not java.io.Serializable; keep the Serializable contract of
    // [SAnime] by not serialising the field (an absent value reads back as empty).
    @Transient
    private var memoValue: JsonObject? = null

    override var memo: JsonObject
        get() = memoValue ?: Video.EMPTY_MEMO
        set(value) {
            memoValue = value
        }

    override var initialized: Boolean = false
}
