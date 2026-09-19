package eu.kanade.tachiyomi.animesource.model

import android.net.Uri
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
 * Hibiki host ABI: this is the extensions-lib 16 shape (the data-class primary
 * constructor, `videoTitle` / `resolution` / `preferred` / `initialized`), which is
 * what the yuzono / Anikku ecosystem and the Aniyomi main line compile against,
 * **plus** the lib-14 surface as a compatibility layer: the `(url, quality, videoUrl,
 * headers, ...)` secondary constructors, the `url` page-URL slot and the `quality`
 * alias. The parameter list and order of the primary constructor must stay exactly
 * as in the lib, because `copy(...)` / `componentN()` / the synthetic default-args
 * constructor are resolved by descriptor at load time.
 *
 * @param videoUrl The url of the video that's passed to mpv.
 * @param videoTitle The title of the video displayed in the app.
 * @param resolution The video resolution. Useful for sorting.
 * @param bitrate The video bitrate. Useful for sorting.
 * @param headers The headers of the video.
 * @param preferred Set to preferred to give priority when loading.
 * Note that multiple videos may have this to true.
 * @param subtitleTracks The list of external subtitle tracks.
 * @param audioTracks The list of external audio tracks.
 * @param timestamps The list of timestamps.
 * @param mpvArgs Extra arguments passed to mpv.
 * @param ffmpegStreamArgs Extra arguments passed to the video stream when downloading.
 * @param ffmpegVideoArgs Extra arguments passed to ffmpeg when downloading.
 * @param internalData Internal data used by resolveVideo.
 * @param initialized Whether resolveVideo has already been applied.
 */
data class Video(
    // `var` rather than the lib's `val`: lib-14 sources assign `video.videoUrl = ...`
    // after `getVideoUrl`. A setter is an addition to the lib's binary surface, never
    // a removal, so lib-16 callers see exactly the ABI they compiled against.
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
) {
    /**
     * lib 14: the page / embed url the video came from, which `videoUrlRequest` fetches
     * when [videoUrl] is unresolved. lib 16 has no such slot, so for videos built with
     * the primary constructor it simply mirrors [videoUrl]. Not part of `equals` /
     * `copy` on purpose: the lib's data-class contract must not change.
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
        videoTitle = quality,
        videoUrl = videoUrl ?: "null",
        headers = headers,
        subtitleTracks = subtitleTracks,
        audioTracks = audioTracks,
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
     * `AnimeVideoLoaderTest` pins both synthetic descriptors.
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
}
