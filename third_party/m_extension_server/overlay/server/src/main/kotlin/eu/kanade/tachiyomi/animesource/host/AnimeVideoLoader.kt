package eu.kanade.tachiyomi.animesource.host

import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource

/**
 * Hibiki host: turns one episode into the flat list of playable [Video]s the
 * player expects, across both extension generations. Shared verbatim by the
 * desktop sidecar and the Android host (the Android build compiles this tree),
 * so the two never disagree on what "the video list of an episode" means.
 *
 * Mirrors what the Aniyomi player does before it hands a URL to mpv:
 *  1. `getHosterList` (lib 16; lib-14 sources answer through the compatibility
 *     default with a single [Hoster.NO_HOSTER_LIST] hoster), then the
 *     extension's `sortHosters`;
 *  2. per hoster, `hoster.videoList ?: getVideoList(hoster)`, then the
 *     extension's `sortVideos` (its quality / language preference ordering);
 *     lazy hosters are only expanded when nothing eager produced a video;
 *  3. per video, `resolveVideo` when not yet `initialized`, then the lib-14
 *     `getVideoUrl` step when the url is still unresolved. Videos that fail to
 *     resolve are dropped, not fatal: one dead mirror must not hide the others.
 *
 * Only when *nothing* survives is the first failure rethrown, so the UI shows
 * the real cause (an HTTP status, a parser exception) instead of an empty list.
 */
object AnimeVideoLoader {
    suspend fun loadVideos(
        source: AnimeSource,
        episode: SEpisode,
    ): List<Video> {
        val hosters = source.getHosterList(episode)
        val ordered = if (source is AnimeHttpSource) source.applyHosterSort(hosters) else hosters
        val failures = mutableListOf<Throwable>()
        val videos = mutableListOf<Video>()

        suspend fun expand(hoster: Hoster) {
            val list =
                try {
                    hoster.videoList ?: source.getVideoList(hoster)
                } catch (error: Exception) {
                    failures += error
                    return
                }
            val sorted = if (source is AnimeHttpSource) source.applyVideoSort(list) else list
            for (video in sorted) {
                val resolved =
                    try {
                        resolve(source, video)
                    } catch (error: Exception) {
                        failures += error
                        null
                    }
                if (resolved != null) videos += resolved
            }
        }

        for (hoster in ordered.filter { !it.lazy }) expand(hoster)
        if (videos.isEmpty()) {
            for (hoster in ordered.filter { it.lazy }) expand(hoster)
        }
        if (videos.isEmpty()) {
            failures.firstOrNull()?.let { throw it }
        }
        return videos
    }

    /**
     * lib 16 `resolveVideo` (skipped once `initialized`), then the lib-14
     * `getVideoUrl` page step for a still-unresolved url. Returns null when the
     * video cannot produce a playable url; throws when the extension's own
     * resolver throws (the caller records it as this video's failure).
     */
    suspend fun resolve(
        source: AnimeSource,
        video: Video,
    ): Video? {
        var current = video
        if (source is AnimeHttpSource) {
            if (!current.initialized) {
                val resolved = source.resolveVideo(current) ?: return null
                // `copy` drops the lib-14 page url slot; carry it over so a legacy
                // `getVideoUrl` below still has something to fetch.
                current = resolved.copy(initialized = true).also { it.url = resolved.url }
            }
            if (current.isVideoUrlUnresolved && current.url.isNotEmpty() && current.url != "null") {
                current.videoUrl = source.getVideoUrl(current)
            }
        }
        return if (current.isVideoUrlUnresolved) null else current
    }
}
