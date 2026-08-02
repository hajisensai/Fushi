package mextensionserver.model

data class DataBody(
    val data: String, // Base64 encoded APK data
    val method: String,
    val page: Int? = null,
    val search: String? = null,
    val filterList: List<JFilterList>? = null,
    val mangaData: MangaData? = null,
    val chapterData: ChapterData? = null,
    val animeData: AnimeData? = null,
    val episodeData: EpisodeData? = null,
    val preferences: MutableList<Map<String, Any>>? = null,
)

data class MangaData(
    val url: String?,
    val title: String?,
    val artist: String?,
    val author: String?,
    val description: String?,
    val genre: String?,
    val status: Int?,
    val thumbnail_url: String?,
    val initialized: Boolean?,
)

data class ChapterData(
    val url: String?,
    val name: String?,
    val date_upload: Long?,
    val chapter_number: Float?,
    val scanlator: String?,
)

data class AnimeData(
    val url: String?,
    val title: String?,
    val artist: String?,
    val author: String?,
    val description: String?,
    val genre: String?,
    val status: Int?,
    val thumbnail_url: String?,
    val initialized: Boolean?,
)

data class EpisodeData(
    val url: String?,
    val name: String?,
    val date_upload: Long?,
    val episode_number: Float?,
    val scanlator: String?,
)

data class JFilterList(
    val name: String?,
    val type: String?,
    val stateString: String?,
    val stateInt: Int?,
    val stateList: List<JGroupFilter>?,
    val stateSort: JSortFilter?,
)

data class JGroupFilter(
    val name: String?,
    val type: String?,
    val stateBoolean: Boolean?,
    val stateInt: Int?,
)

data class JSortFilter(
    val ascending: Boolean?,
    val index: Int?,
)
