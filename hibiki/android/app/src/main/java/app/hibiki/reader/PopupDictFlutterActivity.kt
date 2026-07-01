package app.hibiki.reader

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/**
 * Transparent FlutterActivity (in the :popup process) that hosts the warm
 * popup engine and renders the nested-capable Flutter PopupDictionaryPage for
 * external dictionary lookups. Replaces the old native PopupDictActivity for
 * the PROCESS_TEXT / SEND / TRANSLATE / hibiki://lookup entry points.
 */
class PopupDictFlutterActivity : FlutterActivity() {
    companion object {
        /**
         * Intent extra carrying the tapped glyph index from the floating
         * lyric/subtitle strip. Shared with FloatingLyricService so the two
         * sides cannot drift apart on a magic string.
         */
        const val EXTRA_CHAR_INDEX: String = "charIndex"

        /**
         * Intent extras carrying the tapped glyph's on-screen rectangle (physical
         * px) from the floating lyric/subtitle strip (TODO-872). Defined here, the
         * single owner of the popup intent contract, so FloatingLyricService and
         * this activity cannot drift on a magic string. Their absence means "no
         * anchor" → the Dart popup keeps its default top-center placement, which
         * is exactly what every non-floating entry (system PROCESS_TEXT /
         * hibiki://lookup) wants.
         */
        const val EXTRA_ANCHOR_LEFT: String = "anchorLeft"
        const val EXTRA_ANCHOR_TOP: String = "anchorTop"
        const val EXTRA_ANCHOR_RIGHT: String = "anchorRight"
        const val EXTRA_ANCHOR_BOTTOM: String = "anchorBottom"

        /**
         * Intent extras carrying the whole subtitle-window rectangle (physical px)
         * from the floating lyric/subtitle strip (TODO-708 P1). The Dart popup
         * avoids this superset so the lookup card never covers any glyph in the
         * strip - not just the tapped one. Absent -> Dart avoids only the glyph
         * anchor above, preserving the TODO-872 single-glyph behaviour.
         */
        const val EXTRA_SUBTITLE_LEFT: String = "subtitleLeft"
        const val EXTRA_SUBTITLE_TOP: String = "subtitleTop"
        const val EXTRA_SUBTITLE_RIGHT: String = "subtitleRight"
        const val EXTRA_SUBTITLE_BOTTOM: String = "subtitleBottom"

        @Volatile
        private var webViewDataDirConfigured = false

        /**
         * The popup Flutter engine renders dictionary entries in a
         * flutter_inappwebview WebView inside the :popup process. Android forbids
         * two processes sharing one WebView data directory (crbug.com/558377), so
         * the :popup process must use a distinct suffix before any WebView is
         * created — mirroring the legacy native PopupDictActivity. Must run before
         * the engine renders, hence the first line of onCreate.
         */
        private fun configureWebViewDataDir() {
            if (webViewDataDirConfigured) return
            webViewDataDirConfigured = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    WebView.setDataDirectorySuffix("popup")
                } catch (e: IllegalStateException) {
                    // Another :popup entry point (legacy PopupDictActivity) already
                    // set the suffix in this process — same dir, safe to ignore.
                }
            }
        }
    }

    private var engineWasCold: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Give the :popup WebView its own data directory before anything in this
        // process touches WebView (the engine renders entries via inappwebview).
        configureWebViewDataDir()
        // Set the term BEFORE ensureEngine: a cold start executes the Dart
        // entrypoint inside ensureEngine and Dart immediately polls
        // getInitialProcessText.
        val text: String = extractProcessText(intent).orEmpty()
        val charIndex: Int = extractCharIndex(intent)
        val anchor: IntArray? = extractAnchorRect(intent)
        val subtitle: IntArray? = extractSubtitleRect(intent)
        PopupEngineHolder.setPendingText(text, charIndex, anchor, subtitle)
        engineWasCold = PopupEngineHolder.ensureEngine(this)
        PopupEngineHolder.setOnFinish { runOnUiThread { finish() } }
        super.onCreate(savedInstanceState)
        if (!engineWasCold) {
            // Warm reuse: Dart is already mounted and won't re-poll
            // getInitialProcessText, so push the new term explicitly.
            PopupEngineHolder.pushProcessText(text, charIndex, anchor, subtitle)
        }
    }

    override fun getCachedEngineId(): String = PopupEngineHolder.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        PopupEngineHolder.pushProcessText(
            extractProcessText(intent).orEmpty(),
            extractCharIndex(intent),
            extractAnchorRect(intent),
            extractSubtitleRect(intent),
        )
    }

    override fun onDestroy() {
        PopupEngineHolder.setOnFinish(null)
        super.onDestroy()
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent == null) return null
        intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.let { return it }
        intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let { return it }
        intent.data?.let { uri ->
            if (uri.scheme == "hibiki" && uri.host == "lookup") {
                uri.getQueryParameter("word")?.trim()?.takeIf { it.isNotEmpty() }
                    ?.let { return it }
            }
        }
        return null
    }

    /**
     * Index of the tapped glyph inside the process text, supplied by the
     * floating lyric/subtitle strip (FloatingLyricService.handleTap). Whole-
     * sentence system lookups (PROCESS_TEXT / SEND / TRANSLATE) carry no index,
     * so the default -1 makes the Dart popup search the full text — preserving
     * the existing system-menu behaviour.
     */
    private fun extractCharIndex(intent: Intent?): Int {
        return intent?.getIntExtra(EXTRA_CHAR_INDEX, -1) ?: -1
    }

    /**
     * Tapped-glyph anchor rectangle (physical px: left, top, right, bottom) from
     * the floating lyric/subtitle strip (TODO-872), or {@code null} when the
     * intent carries no anchor (system PROCESS_TEXT / hibiki://lookup) — letting
     * the Dart popup keep its default top-center placement. All four extras must
     * be present; a partial set is treated as no anchor.
     */
    private fun extractAnchorRect(intent: Intent?): IntArray? {
        if (intent == null) return null
        if (!intent.hasExtra(EXTRA_ANCHOR_LEFT) ||
            !intent.hasExtra(EXTRA_ANCHOR_TOP) ||
            !intent.hasExtra(EXTRA_ANCHOR_RIGHT) ||
            !intent.hasExtra(EXTRA_ANCHOR_BOTTOM)
        ) {
            return null
        }
        return intArrayOf(
            intent.getIntExtra(EXTRA_ANCHOR_LEFT, 0),
            intent.getIntExtra(EXTRA_ANCHOR_TOP, 0),
            intent.getIntExtra(EXTRA_ANCHOR_RIGHT, 0),
            intent.getIntExtra(EXTRA_ANCHOR_BOTTOM, 0),
        )
    }

    /**
     * Whole subtitle-window rectangle (physical px: left, top, right, bottom) from
     * the floating lyric/subtitle strip (TODO-708 P1), or {@code null} when the
     * intent carries no subtitle rect (system PROCESS_TEXT / hibiki://lookup, or an
     * overlay not yet laid out). The Dart popup avoids this superset so the card
     * never covers any glyph in the strip. All four extras must be present; a
     * partial set is treated as absent.
     */
    private fun extractSubtitleRect(intent: Intent?): IntArray? {
        if (intent == null) return null
        if (!intent.hasExtra(EXTRA_SUBTITLE_LEFT) ||
            !intent.hasExtra(EXTRA_SUBTITLE_TOP) ||
            !intent.hasExtra(EXTRA_SUBTITLE_RIGHT) ||
            !intent.hasExtra(EXTRA_SUBTITLE_BOTTOM)
        ) {
            return null
        }
        return intArrayOf(
            intent.getIntExtra(EXTRA_SUBTITLE_LEFT, 0),
            intent.getIntExtra(EXTRA_SUBTITLE_TOP, 0),
            intent.getIntExtra(EXTRA_SUBTITLE_RIGHT, 0),
            intent.getIntExtra(EXTRA_SUBTITLE_BOTTOM, 0),
        )
    }
}
