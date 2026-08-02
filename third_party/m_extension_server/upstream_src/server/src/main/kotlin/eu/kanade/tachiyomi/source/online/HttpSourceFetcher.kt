@file:Suppress("EXTENSION_SHADOWED_BY_MEMBER")

package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.source.model.Page
import rx.Observable

fun HttpSource.getImageUrl(page: Page): Observable<Page> = resolveImageUrl(page)

private fun HttpSource.resolveImageUrl(page: Page): Observable<Page> {
    page.status = Page.LOAD_PAGE
    return fetchImageUrl(page)
        .doOnError { page.status = Page.ERROR }
        .onErrorReturn { null }
        .doOnNext { page.imageUrl = it }
        .map { page }
}

fun HttpSource.fetchAllImageUrlsFromPageList(pages: List<Page>): Observable<Page> =
    Observable
        .from(pages)
        .filter { !it.imageUrl.isNullOrEmpty() }
        .mergeWith(fetchRemainingImageUrlsFromPageList(pages))

fun HttpSource.fetchRemainingImageUrlsFromPageList(pages: List<Page>): Observable<Page> =
    Observable
        .from(pages)
        .filter { it.imageUrl.isNullOrEmpty() }
        .concatMap { resolveImageUrl(it) }
