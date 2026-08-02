package eu.kanade.tachiyomi.source

import android.content.Context
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import rx.Observable

class LocalSource(
    private val context: Context,
) : CatalogueSource {
    companion object {
        const val ID = 0L
    }

    override val id = ID
    override val name = "Local source"
    override val lang = ""
    override val supportsLatest = true

    override fun fetchMangaDetails(manga: SManga): Observable<SManga> {
        TODO("Not yet implemented")
    }

    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> {
        TODO("Not yet implemented")
    }

    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> {
        TODO("Not yet implemented")
    }

    override fun fetchPopularManga(page: Int): Observable<MangasPage> {
        TODO("Not yet implemented")
    }

    override fun fetchSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): Observable<MangasPage> {
        TODO("Not yet implemented")
    }

    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> {
        TODO("Not yet implemented")
    }

    override fun getFilterList(): FilterList {
        TODO("Not yet implemented")
    }
}
