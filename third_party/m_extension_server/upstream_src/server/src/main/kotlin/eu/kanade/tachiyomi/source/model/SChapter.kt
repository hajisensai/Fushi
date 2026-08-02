@file:Suppress("ktlint:standard:property-naming")

package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject
import java.io.Serializable

interface SChapter : Serializable {
    var url: String

    var name: String

    var date_upload: Long

    var chapter_number: Float

    var scanlator: String?

    /**
     * Source-specific metadata introduced by TachiyomiX 1.6.
     */
    var memo: JsonObject

    fun copyFrom(other: SChapter) {
        name = other.name
        url = other.url
        date_upload = other.date_upload
        chapter_number = other.chapter_number
        scanlator = other.scanlator
        runCatching { other.memo }.getOrNull()?.let { memo = it }
    }

    companion object {
        fun create(): SChapter = SChapterImpl()
    }
}
