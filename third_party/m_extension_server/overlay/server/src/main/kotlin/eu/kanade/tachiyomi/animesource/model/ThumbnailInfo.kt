package eu.kanade.tachiyomi.animesource.model

/**
 * Seek-preview thumbnails (extensions-lib 17). The host never requests them; the
 * classes exist so lib-17 extensions overriding `getVideoThumbnails` link.
 *
 * @param tileInfo List of tiles to be used as thumbnails.
 * @param imageTileUrls List of urls to image tiles.
 * @since extensions-lib 17
 */
open class ThumbnailInfo(
    val tileInfo: List<TileInfo>,
    val imageTileUrls: List<String>,
)

/**
 * One image tile used as a thumbnail.
 *
 * @since extensions-lib 17
 */
data class TileInfo(
    val imageIndex: Int,
    val timeMs: Long,
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
)
