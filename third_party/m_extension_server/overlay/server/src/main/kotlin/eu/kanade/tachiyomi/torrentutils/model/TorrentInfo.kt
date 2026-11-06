package eu.kanade.tachiyomi.torrentutils.model

import java.net.URLEncoder

/** @since extensions-lib 17 */
data class TorrentInfo(
    val title: String,
    val files: List<TorrentFile>,
    val hash: String,
    val size: Long,
    val trackers: List<String> = emptyList(),
) {
    fun setTrackers(trackers: List<String>): TorrentInfo = copy(trackers = trackers)
}

/** @since extensions-lib 17 */
data class TorrentFile(
    val path: String,
    val indexFile: Int,
    val size: Long,
    private val torrentHash: String,
    private val trackers: List<String> = emptyList(),
) {
    /** Magnet URI selecting this file (`so=` is the BEP 53 file index). */
    fun toMagnetURI(): String =
        buildString {
            append("magnet:?xt=urn:btih:").append(torrentHash)
            append("&dn=").append(URLEncoder.encode(path, Charsets.UTF_8))
            append("&so=").append(indexFile)
            for (tracker in trackers) {
                append("&tr=").append(URLEncoder.encode(tracker, Charsets.UTF_8))
            }
        }
}

/** @since extensions-lib 17 */
class DeadTorrentException : Exception()
