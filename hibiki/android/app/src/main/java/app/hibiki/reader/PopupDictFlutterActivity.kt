package app.hibiki.reader

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * Transparent FlutterActivity (in the :popup process) that hosts the warm
 * popup engine and renders the nested-capable Flutter PopupDictionaryPage for
 * external dictionary lookups. Replaces the old native PopupDictActivity for
 * the PROCESS_TEXT / SEND / TRANSLATE / hibiki://lookup entry points.
 */
class PopupDictFlutterActivity : FlutterActivity() {
    private var engineWasCold: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Set the term BEFORE ensureEngine: a cold start executes the Dart
        // entrypoint inside ensureEngine and Dart immediately polls
        // getInitialProcessText.
        val text: String = extractProcessText(intent).orEmpty()
        PopupEngineHolder.setPendingText(text)
        engineWasCold = PopupEngineHolder.ensureEngine(this)
        PopupEngineHolder.setOnFinish { runOnUiThread { finish() } }
        super.onCreate(savedInstanceState)
        if (!engineWasCold) {
            // Warm reuse: Dart is already mounted and won't re-poll
            // getInitialProcessText, so push the new term explicitly.
            PopupEngineHolder.pushProcessText(text)
        }
    }

    override fun getCachedEngineId(): String = PopupEngineHolder.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        PopupEngineHolder.pushProcessText(extractProcessText(intent).orEmpty())
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
}
