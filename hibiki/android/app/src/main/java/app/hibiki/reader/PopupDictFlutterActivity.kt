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
        PopupEngineHolder.setPendingText(text, charIndex)
        engineWasCold = PopupEngineHolder.ensureEngine(this)
        PopupEngineHolder.setOnFinish { runOnUiThread { finish() } }
        super.onCreate(savedInstanceState)
        if (!engineWasCold) {
            // Warm reuse: Dart is already mounted and won't re-poll
            // getInitialProcessText, so push the new term explicitly.
            PopupEngineHolder.pushProcessText(text, charIndex)
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
}
