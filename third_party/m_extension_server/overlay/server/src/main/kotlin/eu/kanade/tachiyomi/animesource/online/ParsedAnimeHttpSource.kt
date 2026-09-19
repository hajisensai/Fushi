package eu.kanade.tachiyomi.animesource.online

import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.util.asJsoup
import okhttp3.Response
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

/**
 * A simple implementation for sources from a website using Jsoup, an HTML parser.
 */
abstract class ParsedAnimeHttpSource : AnimeHttpSource() {
    /**
     * Parses the response from the site and returns a [AnimesPage] object.
     *
     * @param response the response from the site.
     */
    override fun popularAnimeParse(response: Response): AnimesPage {
        val document = response.asJsoup()

        val animes =
            document
                .select(popularAnimeSelector())
                .map(::popularAnimeFromElement)

        val hasNextPage =
            popularAnimeNextPageSelector()
                ?.let(document::selectFirst) != null

        return AnimesPage(animes, hasNextPage)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each anime.
     */
    protected abstract fun popularAnimeSelector(): String

    /**
     * Returns a anime from the given [element]. Most sites only show the title and the url, it's
     * totally fine to fill only those two values.
     *
     * @param element an element obtained from [popularAnimeSelector].
     */
    protected abstract fun popularAnimeFromElement(element: Element): SAnime

    /**
     * Returns the Jsoup selector that returns the <a> tag linking to the next page, or null if
     * there's no next page.
     */
    protected abstract fun popularAnimeNextPageSelector(): String?

    /**
     * Parses the response from the site and returns a [AnimesPage] object.
     *
     * @param response the response from the site.
     */
    override fun searchAnimeParse(response: Response): AnimesPage {
        val document = response.asJsoup()

        val animes =
            document
                .select(searchAnimeSelector())
                .map(::searchAnimeFromElement)

        val hasNextPage =
            searchAnimeNextPageSelector()
                ?.let(document::selectFirst) != null

        return AnimesPage(animes, hasNextPage)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each anime.
     */
    protected abstract fun searchAnimeSelector(): String

    /**
     * Returns a anime from the given [element]. Most sites only show the title and the url, it's
     * totally fine to fill only those two values.
     *
     * @param element an element obtained from [searchAnimeSelector].
     */
    protected abstract fun searchAnimeFromElement(element: Element): SAnime

    /**
     * Returns the Jsoup selector that returns the <a> tag linking to the next page, or null if
     * there's no next page.
     */
    protected abstract fun searchAnimeNextPageSelector(): String?

    /**
     * Parses the response from the site and returns a [AnimesPage] object.
     *
     * @param response the response from the site.
     */
    override fun latestUpdatesParse(response: Response): AnimesPage {
        val document = response.asJsoup()

        val animes =
            document
                .select(latestUpdatesSelector())
                .map(::latestUpdatesFromElement)

        val hasNextPage =
            latestUpdatesNextPageSelector()
                ?.let(document::selectFirst) != null

        return AnimesPage(animes, hasNextPage)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each anime.
     */
    protected abstract fun latestUpdatesSelector(): String

    /**
     * Returns a anime from the given [element]. Most sites only show the title and the url, it's
     * totally fine to fill only those two values.
     *
     * @param element an element obtained from [latestUpdatesSelector].
     */
    protected abstract fun latestUpdatesFromElement(element: Element): SAnime

    /**
     * Returns the Jsoup selector that returns the <a> tag linking to the next page, or null if
     * there's no next page.
     */
    protected abstract fun latestUpdatesNextPageSelector(): String?

    /**
     * Parses the response from the site and returns the details of a anime.
     *
     * @param response the response from the site.
     */
    override fun animeDetailsParse(response: Response): SAnime = animeDetailsParse(response.asJsoup())

    /**
     * Returns the details of the anime from the given [document].
     *
     * @param document the parsed document.
     */
    protected abstract fun animeDetailsParse(document: Document): SAnime

    /**
     * Parses the response from the site and returns a list of episodes.
     *
     * @param response the response from the site.
     */
    override fun episodeListParse(response: Response): List<SEpisode> {
        val document = response.asJsoup()
        return document.select(episodeListSelector()).map(::episodeFromElement)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each episode.
     */
    protected abstract fun episodeListSelector(): String

    /**
     * Returns a episode from the given element.
     *
     * @param element an element obtained from [episodeListSelector].
     */
    protected abstract fun episodeFromElement(element: Element): SEpisode


    // AY -->
    /**
     * Parses the response from the site and returns a list of seasons.
     *
     * @since extensions-lib 16
     * @param response the response from the site.
     */
    override fun seasonListParse(response: Response): List<SAnime> {
        val document = response.asJsoup()
        return document.select(seasonListSelector()).map(::seasonFromElement)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each season.
     *
     * lib 16 declares this abstract; open here so lib-14 classes load.
     *
     * @since extensions-lib 16
     */
    protected open fun seasonListSelector(): String = throw UnsupportedOperationException()

    /**
     * Returns a season from the given element.
     *
     * @since extensions-lib 16
     * @param element an element obtained from [seasonListSelector].
     */
    protected open fun seasonFromElement(element: Element): SAnime = throw UnsupportedOperationException()
    // <-- AY

    /**
     * Parses the response from the site and returns a list of hosters.
     *
     * @since extensions-lib 16
     * @param response the response from the site.
     */
    override fun hosterListParse(response: Response): List<Hoster> {
        val document = response.asJsoup()
        return document.select(hosterListSelector()).map(::hosterFromElement)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each hoster.
     *
     * @since extensions-lib 16
     */
    protected open fun hosterListSelector(): String = throw UnsupportedOperationException()

    /**
     * Returns a hoster from the given element.
     *
     * @since extensions-lib 16
     * @param element an element obtained from [hosterListSelector].
     */
    protected open fun hosterFromElement(element: Element): Hoster = throw UnsupportedOperationException()

    /**
     * A parsed lib-16 source implements the selector pair rather than
     * [hosterListParse] itself; both count as "uses the hoster API".
     */
    override val implementsHosterParser: Boolean by lazy {
        declaresOverride("hosterListParse", Response::class.java) ||
            declaresOverride("hosterListSelector") ||
            declaresOverride("hosterFromElement", Element::class.java)
    }

    /**
     * Parses the response from the site and returns the page list.
     *
     * @param response the response from the site.
     */
    override fun videoListParse(response: Response): List<Video> {
        val document = response.asJsoup()
        return document.select(videoListSelector()).map(::videoFromElement)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each video.
     *
     * lib 14 declares this abstract; open here so lib-16 classes load.
     */
    protected open fun videoListSelector(): String = throw UnsupportedOperationException()

    /**
     * Returns a video from the given element.
     *
     * @param element an element obtained from [videoListSelector].
     */
    protected open fun videoFromElement(element: Element): Video = throw UnsupportedOperationException()

    /**
     * Parse the response from the site and returns the absolute url to the source video.
     *
     * @param response the response from the site.
     */
    override fun videoUrlParse(response: Response): String = videoUrlParse(response.asJsoup())

    /**
     * Returns the absolute url to the source image from the document.
     *
     * lib 14 declares this abstract; open here so lib-16 classes load.
     *
     * @param document the parsed document.
     */
    protected open fun videoUrlParse(document: Document): String = throw UnsupportedOperationException()
}
