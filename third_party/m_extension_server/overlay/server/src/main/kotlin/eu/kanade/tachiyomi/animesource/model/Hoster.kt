package eu.kanade.tachiyomi.animesource.model

import kotlinx.serialization.json.JsonObject

/**
 * Fushi host ABI: the lib-16 hoster plus the lib-17 `memo` slot. Both generations
 * construct hosters through the synthetic default-argument constructor of *their*
 * parameter list (lib 16 `<init>(String, String, List, String, boolean, int,
 * DefaultConstructorMarker)`, lib 17 the same with a `JsonObject` before the mask),
 * so both constructors exist here; `AnimeVideoLoaderTest` pins the descriptors.
 *
 * @param memo Source-private metadata (lib 17), handed back to the extension untouched.
 */
open class Hoster(
    val hosterUrl: String = "",
    val hosterName: String = "",
    val videoList: List<Video>? = null,
    val internalData: String = "",
    val lazy: Boolean = false,
    val memo: JsonObject = Video.EMPTY_MEMO,
) {
    /** lib 16 shape: the primary constructor before lib 17 appended `memo`. */
    constructor(
        hosterUrl: String = "",
        hosterName: String = "",
        videoList: List<Video>? = null,
        internalData: String = "",
        lazy: Boolean = false,
    ) : this(hosterUrl, hosterName, videoList, internalData, lazy, Video.EMPTY_MEMO)

    @Transient
    @Volatile
    var status: State = State.IDLE

    enum class State {
        IDLE,
        LOADING,
        READY,
        ERROR,
    }

    /** lib 16 `copy`; [memo] is carried over unchanged. */
    fun copy(
        hosterUrl: String = this.hosterUrl,
        hosterName: String = this.hosterName,
        videoList: List<Video>? = this.videoList,
        internalData: String = this.internalData,
        lazy: Boolean = this.lazy,
    ): Hoster = Hoster(hosterUrl, hosterName, videoList, internalData, lazy, memo)

    companion object {
        const val NO_HOSTER_LIST = "no_hoster_list"

        fun List<Video>.toHosterList(): List<Hoster> =
            listOf(
                Hoster(
                    hosterUrl = "",
                    hosterName = NO_HOSTER_LIST,
                    videoList = this,
                ),
            )
    }
}
