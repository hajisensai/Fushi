package eu.kanade.tachiyomi.torrentutils;

import eu.kanade.tachiyomi.torrentutils.model.TorrentInfo;
import kotlin.coroutines.Continuation;

/**
 * Aniyomi's torrent helper, as extensions link against it.
 *
 * Two generations call it with different JVM descriptors for the same Kotlin
 * name: the yuzono / komikku-app lib (measured in yuzono "14.x" torrent APKs)
 * declares a plain {@code getTorrentInfo(String, String)}, extensions-lib 17 a
 * {@code suspend} one, i.e. {@code getTorrentInfo(String, String, Continuation)}.
 * Kotlin cannot declare both on one {@code object} (a {@code suspend} modifier
 * does not distinguish overloads), so this one class is Java; {@code INSTANCE}
 * keeps the Kotlin {@code object} shape the dex reads.
 *
 * Aniyomi answers it from its own torrent engine; this host does not expose one to
 * extensions, so the call fails with a readable message (recorded as that
 * candidate's failure) instead of {@code NoClassDefFoundError} when the extension
 * class loads.
 */
public final class TorrentUtils {
    public static final TorrentUtils INSTANCE = new TorrentUtils();

    private static final String UNSUPPORTED = "Torrent metadata is not available to extensions in Fushi";

    private TorrentUtils() {
    }

    /** komikku-app lib shape. */
    public TorrentInfo getTorrentInfo(String url, String title) {
        throw new UnsupportedOperationException(UNSUPPORTED);
    }

    /** extensions-lib 17 shape ({@code suspend fun getTorrentInfo(url, title)}). */
    public Object getTorrentInfo(String url, String title, Continuation<? super TorrentInfo> continuation) {
        throw new UnsupportedOperationException(UNSUPPORTED);
    }
}
