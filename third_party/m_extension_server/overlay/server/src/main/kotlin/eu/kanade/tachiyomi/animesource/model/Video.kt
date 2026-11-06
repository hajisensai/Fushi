package eu.kanade.tachiyomi.animesource.model

import android.net.Uri
import kotlinx.serialization.json.JsonObject
import okhttp3.Headers

/**
 * A sub/dub track.
 */
data class Track(
    val url: String,
    val lang: String,
)

enum class ChapterType {
    Opening,
    Ending,
    Recap,
    MixedOp,
    Other,
}

/**
 * A class defining a timestamp. Displayed as video chapters in the app.
 *
 * @param start Start of the timestamp, in seconds.
 * @param end End of the timestamp, in seconds.
 * @param name Display name of timestamp.
 * @param type Type of timestamp.
 */
data class TimeStamp(
    val start: Double,
    val end: Double,
    val name: String,
    val type: ChapterType = ChapterType.Other,
)

/**
 * The instance that contains the data needed to watch a video.
 *
 * Fushi host ABI: the union of three generations, each of which an extension's dex
 * links against **by JVM descriptor**:
 *  - extensions-lib 17: the data-class primary constructor ending in `memo`
 *    (`JsonObject`), and its `copy(..., memo)`;
 *  - extensions-lib 16 (yuzono / Anikku / komikku-app, versionName often still "14.x"):
 *    the same parameter list **without** `memo`, and its 14-parameter `copy`. Real
 *    lib-16 APKs call `Video.copy$default(Video, <14 params>, int, Object)` from their
 *    `resolveVideo` (23 of the 47 yuzono lib-16 APKs, measured 2026-10-23), so that
 *    descriptor must stay even though lib 17 replaced it;
 *  - extensions-lib 14: the `(url, quality, videoUrl, headers, ...)` secondary
 *    constructors, the `url` page-URL slot and the `quality` alias.
 *
 * A Kotlin `data class` only generates `copy` / `componentN` / the synthetic
 * default-argument constructor for its primary constructor, so it cannot carry two
 * generations at once. This is therefore a plain class that spells out both
 * constructors, both `copy` overloads and `component1..15`, with value semantics
 * (`equals` / `hashCode` / `toString`) over the lib-17 property set. Host code that
 * calls `copy(...)` without naming `memo` resolves to the 14-parameter overload
 * (fewer unspecified defaults), which carries `memo` over unchanged.
 *
 * `AnimeVideoLoaderTest` pins every synthetic descriptor listed above.
 *
 * @param videoUrl The url of the video that's passed to mpv.
 * @param videoTitle The title of the video displayed in the app.
 * @param resolution The video resolution. Useful for sorting.
 * @param bitrate The video bitrate. Useful for sorting.
 * @param headers The headers of the video.
 * @param preferred Set to preferred to give priority when loading.
 * @param subtitleTracks The list of external subtitle tracks.
 * @param audioTracks The list of external audio tracks.
 * @param timestamps The list of timestamps.
 * @param mpvArgs Extra arguments passed to mpv.
 * @param ffmpegStreamArgs Extra arguments passed to the video stream when downloading.
 * @param ffmpegVideoArgs Extra arguments passed to ffmpeg when downloading.
 * @param internalData Internal data used by resolveVideo (lib 16; lib 17 moved to [memo]).
 * @param initialized Whether resolveVideo has already been applied.
 * @param memo Source-private metadata (lib 17), handed back to the extension untouched.
 */
@Suppress("unused")
class Video(
    // `var` rather than the lib's `val`: lib-14 sources assign `video.videoUrl = ...`
    // after `getVideoUrl`. A setter is an addition to the lib's binary surface, never
    // a removal, so lib-16/17 callers see exactly the ABI they compiled against.
    var videoUrl: String = "",
    val videoTitle: String = "",
    val resolution: Int? = null,
    val bitrate: Int? = null,
    val headers: Headers? = null,
    val preferred: Boolean = false,
    val subtitleTracks: List<Track> = emptyList(),
    val audioTracks: List<Track> = emptyList(),
    val timestamps: List<TimeStamp> = emptyList(),
    val mpvArgs: List<Pair<String, String>> = emptyList(),
    val ffmpegStreamArgs: List<Pair<String, String>> = emptyList(),
    val ffmpegVideoArgs: List<Pair<String, String>> = emptyList(),
    val internalData: String = "",
    val initialized: Boolean = false,
    val memo: JsonObject = EMPTY_MEMO,
) {
    /** lib 16 shape: the primary constructor before lib 17 appended `memo`. */
    constructor(
        videoUrl: String = "",
        videoTitle: String = "",
        resolution: Int? = null,
        bitrate: Int? = null,
        headers: Headers? = null,
        preferred: Boolean = false,
        subtitleTracks: List<Track> = emptyList(),
        audioTracks: List<Track> = emptyList(),
        timestamps: List<TimeStamp> = emptyList(),
        mpvArgs: List<Pair<String, String>> = emptyList(),
        ffmpegStreamArgs: List<Pair<String, String>> = emptyList(),
        ffmpegVideoArgs: List<Pair<String, String>> = emptyList(),
        internalData: String = "",
        initialized: Boolean = false,
    ) : this(
        videoUrl,
        videoTitle,
        resolution,
        bitrate,
        headers,
        preferred,
        subtitleTracks,
        audioTracks,
        timestamps,
        mpvArgs,
        ffmpegStreamArgs,
        ffmpegVideoArgs,
        internalData,
        initialized,
        EMPTY_MEMO,
    )

    /**
     * lib 14: the page / embed url the video came from, which `videoUrlRequest` fetches
     * when [videoUrl] is unresolved. lib 16/17 have no such slot, so for videos built
     * with the primary constructors it simply mirrors [videoUrl]. Not part of `equals` /
     * `copy` on purpose: the lib's value contract must not change.
     */
    var url: String = videoUrl

    /** lib 14 alias of [videoTitle]. */
    val quality: String
        get() = videoTitle

    /** lib 14 shape. The lib maps a null `videoUrl` to the literal string "null". */
    @Deprecated(
        message = "Use the new Video constructor",
        level = DeprecationLevel.WARNING,
        replaceWith = ReplaceWith(
            expression =
                "Video(videoTitle = quality, videoUrl = videoUrl, headers = headers, " +
                    "subtitleTracks = subtitleTracks, audioTracks = audioTracks)",
        ),
    )
    constructor(
        url: String,
        quality: String,
        videoUrl: String?,
        headers: Headers? = null,
        subtitleTracks: List<Track> = emptyList(),
        audioTracks: List<Track> = emptyList(),
    ) : this(
        videoUrl ?: "null",
        quality,
        null,
        null,
        headers,
        false,
        subtitleTracks,
        audioTracks,
        emptyList(),
        emptyList(),
        emptyList(),
        emptyList(),
        "",
        false,
        EMPTY_MEMO,
    ) {
        this.url = url
    }

    /**
     * Oldest lib-14 shape (the `uri` parameter was already ignored upstream). The
     * defaults are **required**, not a convenience: the lib-14 stub declares this
     * constructor as `(url, quality, videoUrl, uri: Uri? = null, headers: Headers? = null)`,
     * and Kotlin resolves the ubiquitous three-argument `Video(url, quality, videoUrl)`
     * call in extension code to *this* overload (fewer unspecified defaults than the
     * six-parameter one above), so the dex links against the synthetic
     * `<init>(String, String, String, Uri, Headers, int, DefaultConstructorMarker)`.
     * Dropping the defaults removes that synthetic constructor and every real lib-14
     * APK dies with `NoSuchMethodError` at `getVideoList` (BUG-2600 review).
     */
    @Suppress("UNUSED_PARAMETER", "DEPRECATION")
    constructor(
        url: String,
        quality: String,
        videoUrl: String?,
        uri: Uri? = null,
        headers: Headers? = null,
    ) : this(url, quality, videoUrl, headers)

    /**
     * Whether [videoUrl] still needs the lib-14 `getVideoUrl` step. The lib-16
     * deprecated constructor stores a null url as the string "null"; the lib-14
     * host treated null and empty alike.
     */
    val isVideoUrlUnresolved: Boolean
        get() = videoUrl.isEmpty() || videoUrl == "null"

    /** lib 17 `copy`. */
    fun copy(
        videoUrl: String = this.videoUrl,
        videoTitle: String = this.videoTitle,
        resolution: Int? = this.resolution,
        bitrate: Int? = this.bitrate,
        headers: Headers? = this.headers,
        preferred: Boolean = this.preferred,
        subtitleTracks: List<Track> = this.subtitleTracks,
        audioTracks: List<Track> = this.audioTracks,
        timestamps: List<TimeStamp> = this.timestamps,
        mpvArgs: List<Pair<String, String>> = this.mpvArgs,
        ffmpegStreamArgs: List<Pair<String, String>> = this.ffmpegStreamArgs,
        ffmpegVideoArgs: List<Pair<String, String>> = this.ffmpegVideoArgs,
        internalData: String = this.internalData,
        initialized: Boolean = this.initialized,
        memo: JsonObject = this.memo,
    ): Video =
        Video(
            videoUrl,
            videoTitle,
            resolution,
            bitrate,
            headers,
            preferred,
            subtitleTracks,
            audioTracks,
            timestamps,
            mpvArgs,
            ffmpegStreamArgs,
            ffmpegVideoArgs,
            internalData,
            initialized,
            memo,
        )

    /** lib 16 `copy` (no `memo` parameter); [memo] is carried over unchanged. */
    fun copy(
        videoUrl: String = this.videoUrl,
        videoTitle: String = this.videoTitle,
        resolution: Int? = this.resolution,
        bitrate: Int? = this.bitrate,
        headers: Headers? = this.headers,
        preferred: Boolean = this.preferred,
        subtitleTracks: List<Track> = this.subtitleTracks,
        audioTracks: List<Track> = this.audioTracks,
        timestamps: List<TimeStamp> = this.timestamps,
        mpvArgs: List<Pair<String, String>> = this.mpvArgs,
        ffmpegStreamArgs: List<Pair<String, String>> = this.ffmpegStreamArgs,
        ffmpegVideoArgs: List<Pair<String, String>> = this.ffmpegVideoArgs,
        internalData: String = this.internalData,
        initialized: Boolean = this.initialized,
    ): Video =
        Video(
            videoUrl,
            videoTitle,
            resolution,
            bitrate,
            headers,
            preferred,
            subtitleTracks,
            audioTracks,
            timestamps,
            mpvArgs,
            ffmpegStreamArgs,
            ffmpegVideoArgs,
            internalData,
            initialized,
            memo,
        )

    operator fun component1(): String = videoUrl

    operator fun component2(): String = videoTitle

    operator fun component3(): Int? = resolution

    operator fun component4(): Int? = bitrate

    operator fun component5(): Headers? = headers

    operator fun component6(): Boolean = preferred

    operator fun component7(): List<Track> = subtitleTracks

    operator fun component8(): List<Track> = audioTracks

    operator fun component9(): List<TimeStamp> = timestamps

    operator fun component10(): List<Pair<String, String>> = mpvArgs

    operator fun component11(): List<Pair<String, String>> = ffmpegStreamArgs

    operator fun component12(): List<Pair<String, String>> = ffmpegVideoArgs

    operator fun component13(): String = internalData

    operator fun component14(): Boolean = initialized

    operator fun component15(): JsonObject = memo

    private fun values(): List<Any?> =
        listOf(
            videoUrl,
            videoTitle,
            resolution,
            bitrate,
            headers,
            preferred,
            subtitleTracks,
            audioTracks,
            timestamps,
            mpvArgs,
            ffmpegStreamArgs,
            ffmpegVideoArgs,
            internalData,
            initialized,
            memo,
        )

    override fun equals(other: Any?): Boolean = this === other || (other is Video && values() == other.values())

    override fun hashCode(): Int = values().hashCode()

    override fun toString(): String =
        "Video(videoUrl=$videoUrl, videoTitle=$videoTitle, resolution=$resolution, " +
            "bitrate=$bitrate, headers=$headers, preferred=$preferred, " +
            "subtitleTracks=$subtitleTracks, audioTracks=$audioTracks, timestamps=$timestamps, " +
            "mpvArgs=$mpvArgs, ffmpegStreamArgs=$ffmpegStreamArgs, ffmpegVideoArgs=$ffmpegVideoArgs, " +
            "internalData=$internalData, initialized=$initialized, memo=$memo)"

    companion object {
        /** Shared empty `memo`; `JsonObject` is immutable. */
        val EMPTY_MEMO: JsonObject = JsonObject(emptyMap())
    }
}
