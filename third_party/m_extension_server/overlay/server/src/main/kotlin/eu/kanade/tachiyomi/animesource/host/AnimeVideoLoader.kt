package eu.kanade.tachiyomi.animesource.host

import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

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
 *
 * **Hosters are expanded concurrently** (BUG-2617). Step 2 is a real HTTP round
 * trip per hoster and step 3 one more per candidate, so an episode with several
 * mirrors used to be dozens of round trips strictly back to back: the caller
 * waited far longer than any client is willing to, and the source looked like it
 * "always times out" even when every mirror was healthy. Aniyomi has always
 * fanned its hoster jobs out together (`HosterLoader`); doing the same collapses
 * the wall clock to roughly the slowest single hoster.
 *
 * The fan-out stops at the hoster boundary. Candidates *within* one hoster stay
 * sequential because they all hit the same site, which is precisely where a
 * burst gets rate-limited or refused — Aniyomi draws the line in the same place.
 * [MAX_CONCURRENT_RESOLVES] caps the hoster fan-out on top of that: every
 * request here goes back out through the host's proxy policy and rate limiters.
 *
 * The fan-out runs on [Dispatchers.IO], not on whatever thread `runBlocking`
 * happened to be on. That is load-bearing rather than tidiness: plenty of lib-14
 * extensions do plain blocking `execute()` / `awaitSingle()` inside their
 * suspend functions, and on a single-threaded dispatcher those block the one
 * thread and run one after another — the fan-out would compile, pass a
 * suspend-only test, and still be serial in production.
 *
 * Ordering is unaffected: `awaitAll` preserves the extension's hoster order and
 * failures are collected in that same order, so "the first failure" still means
 * the first one the extension listed, not whichever lost the race.
 */
object AnimeVideoLoader {
    /**
     * Upper bound on hosters expanded at once for one episode. Clearly above the
     * common case (2–4 mirrors) while staying inside what one client may ask of
     * a site — and of the host's own per-request proxy-policy round trip.
     */
    private const val MAX_CONCURRENT_RESOLVES = 8

    private class Expansion(
        val videos: List<Video>,
        val failures: List<Throwable>,
    )

    suspend fun loadVideos(
        source: AnimeSource,
        episode: SEpisode,
    ): List<Video> {
        val hosters = source.getHosterList(episode)
        val ordered = if (source is AnimeHttpSource) source.applyHosterSort(hosters) else hosters
        val gate = Semaphore(MAX_CONCURRENT_RESOLVES)
        val failures = mutableListOf<Throwable>()

        suspend fun expand(group: List<Hoster>): List<Video> {
            if (group.isEmpty()) return emptyList()
            val expansions =
                coroutineScope {
                    group
                        .map { hoster -> async(Dispatchers.IO) { expandHoster(source, hoster, gate) } }
                        .awaitAll()
                }
            failures += expansions.flatMap { it.failures }
            return expansions.flatMap { it.videos }
        }

        var videos = expand(ordered.filter { !it.lazy })
        if (videos.isEmpty()) {
            videos = expand(ordered.filter { it.lazy })
        }
        if (videos.isEmpty()) {
            failures.firstOrNull()?.let { throw it }
        }
        return videos
    }

    private suspend fun expandHoster(
        source: AnimeSource,
        hoster: Hoster,
        gate: Semaphore,
    ): Expansion {
        val list =
            try {
                hoster.videoList ?: gate.withPermit { source.getVideoList(hoster) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                return Expansion(emptyList(), listOf(error))
            }
        val sorted = if (source is AnimeHttpSource) source.applyVideoSort(list) else list
        val videos = mutableListOf<Video>()
        val failures = mutableListOf<Throwable>()
        // Candidates of one hoster are resolved in order, not fanned out: they all
        // hit the *same* site, which is exactly where a burst gets rate-limited or
        // refused. Aniyomi parallelises hosters and no further, for the same reason.
        for (video in sorted) {
            try {
                resolve(source, video)?.let { videos += it }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                failures += error
            }
        }
        return Expansion(videos = videos, failures = failures)
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
        return if (current.isVideoUrlUnresolved) null else withSourceHeaders(source, current)
    }

    /**
     * A candidate that carries no headers of its own inherits the source's
     * (BUG-2617). `Video.headers` is null unless the extension set it explicitly,
     * and the player is the only thing that fetches this URL — it has no other way
     * to learn the site's Referer / User-Agent, so a hotlink-protected CDN answers
     * 403 and the episode never opens. Aniyomi resolves the same way wherever it
     * hands a video to the player (`video.headers ?: source.headers`).
     */
    private fun withSourceHeaders(
        source: AnimeSource,
        video: Video,
    ): Video {
        if (video.headers != null || source !is AnimeHttpSource) return video
        // `headers` is the extension's own `headersBuilder()`, which is arbitrary
        // extension code and may throw (a missing preference, an uninitialised
        // dependency). Falling back to "no extra headers" is strictly better than
        // losing an otherwise playable candidate over a header we only wanted as a
        // default.
        val sourceHeaders =
            try {
                source.headers
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                return video
            }
        // `copy` rebuilds `url` from `videoUrl` (it is not a data-class property);
        // carry the lib-14 page url over so nothing downstream loses it.
        return video.copy(headers = sourceHeaders).also { it.url = video.url }
    }
}
