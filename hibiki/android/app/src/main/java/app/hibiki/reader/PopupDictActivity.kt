package app.hibiki.reader

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.EditText
import android.widget.ImageButton
import android.widget.LinearLayout
import android.app.Activity
import org.json.JSONArray
import java.io.ByteArrayInputStream
import java.util.Locale
import java.util.concurrent.Executors

class PopupDictActivity : Activity() {
    companion object {
        private const val TAG = "PopupDictActivity"

        @Volatile
        private var bridgeInitialized = false

        @Volatile
        private var webViewDataDirConfigured = false
    }

    private lateinit var webView: WebView
    private lateinit var searchField: EditText
    private val dbReader = PopupDbReader()
    private var ankiDroid: AnkiDroidHelper? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var currentSearchTerm = ""
    private var cachedPrefs: PopupDbReader.PopupPrefs? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        configureWebViewDataDir()
        super.onCreate(savedInstanceState)

        val processText = extractProcessText(intent)

        ioExecutor.execute {
            val t0 = System.currentTimeMillis()
            initBridge()
            val elapsed = System.currentTimeMillis() - t0
            Log.d(TAG, "bridge init: ${elapsed}ms")
        }

        ankiDroid = AnkiDroidHelper(this)
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val result = tts?.setLanguage(Locale.JAPAN)
                ttsReady = result != TextToSpeech.LANG_MISSING_DATA
                        && result != TextToSpeech.LANG_NOT_SUPPORTED
            }
        }

        buildLayout()
        applyPopupWindowSize()

        if (processText != null) {
            searchField.setText(processText)
            currentSearchTerm = processText
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val text = extractProcessText(intent)
        if (text != null) {
            searchField.setText(text)
            performSearch(text)
        }
    }

    override fun onDestroy() {
        ioExecutor.shutdownNow()
        tts?.shutdown()
        webView.destroy()
        super.onDestroy()
    }

    private fun initBridge() {
        synchronized(Companion) {
            if (!bridgeInitialized) {
                HoshiBridge.initialize(applicationContext, dbReader)
                bridgeInitialized = true
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun buildLayout() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0x00000000)
        }

        val searchBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(8, 4, 8, 4)
        }

        searchField = EditText(this).apply {
            hint = "Search"
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnEditorActionListener { _, actionId, event ->
                if (actionId == EditorInfo.IME_ACTION_SEARCH ||
                    (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
                ) {
                    val q = text?.toString()?.trim() ?: ""
                    if (q.isNotEmpty()) performSearch(q)
                    true
                } else false
            }
        }

        val searchBtn = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_search)
            setOnClickListener {
                val q = searchField.text?.toString()?.trim() ?: ""
                if (q.isNotEmpty()) performSearch(q)
            }
        }

        searchBar.addView(searchField)
        searchBar.addView(searchBtn)
        root.addView(searchBar)

        webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = true
            settings.allowFileAccessFromFileURLs = false
            settings.allowUniversalAccessFromFileURLs = false
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f
            )
        }
        webView.addJavascriptInterface(PopupJsInterface(), "androidBridge")
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                if (currentSearchTerm.isNotEmpty()) {
                    performSearch(currentSearchTerm)
                }
            }

            override fun shouldInterceptRequest(
                view: WebView?, request: WebResourceRequest?
            ): WebResourceResponse? {
                val url = request?.url ?: return null
                if (url.scheme == "image" || url.scheme == "dictmedia") {
                    return handleMediaRequest(url)
                }
                return super.shouldInterceptRequest(view, request)
            }
        }

        val popupHtml = buildPopupHtml()
        webView.loadDataWithBaseURL(
            "file:///android_asset/flutter_assets/assets/popup/",
            popupHtml, "text/html", "utf-8", null
        )

        root.addView(webView)
        setContentView(root)
    }

    private fun buildPopupHtml(): String {
        val css = readAsset("flutter_assets/assets/popup/popup.css")
        val dictMediaJs = readAsset("flutter_assets/assets/popup/dict-media.js")
        val selectionJs = readAsset("flutter_assets/assets/popup/selection.js")
        val popupJs = readAsset("flutter_assets/assets/popup/popup.js")

        val bridgeJs = """
            // Bridge: forward JS calls to Android native
            window.flutter_inappwebview = {
                callHandler: function(name, ...args) {
                    if (name === 'tapOutside') androidBridge.tapOutside();
                    else if (name === 'scrolledToBottom') androidBridge.scrolledToBottom();
                    else if (name === 'mineEntry') return Promise.resolve(androidBridge.mineEntry(JSON.stringify(args[0])));
                    else if (name === 'textSelected') androidBridge.textSelected(JSON.stringify(args));
                    else if (name === 'onLinkClick') androidBridge.onLinkClick(args[0]?.toString() || '');
                    else if (name === 'openLink') androidBridge.openLink(args[0]?.toString() || '');
                    else if (name === 'duplicateCheck') return Promise.resolve(false);
                    else if (name === 'resolveWordAudio') return Promise.resolve(null);
                    else if (name === 'queryLocalAudio') return Promise.resolve(null);
                    else if (name === 'playWordAudio') return Promise.resolve(false);
                    return Promise.resolve(null);
                }
            };
        """

        return """<!DOCTYPE html>
<html data-theme="light">
<head>
<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
<style>${css.replace("</style", "<\\/style")}</style>
<script>$bridgeJs</script>
<script>$dictMediaJs</script>
<script>$selectionJs</script>
<script>$popupJs</script>
</head>
<body>
<div id="entries-container"></div>
<div class="overlay">
  <div class="overlay-close" onclick="closeOverlay()">×</div>
  <div class="overlay-content"></div>
</div>
</body></html>"""
    }

    private fun readAsset(path: String): String {
        return try {
            assets.open(path).bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            Log.e(TAG, "readAsset($path) failed", e)
            ""
        }
    }

    private fun performSearch(query: String) {
        currentSearchTerm = query
        ioExecutor.execute {
            val t0 = System.currentTimeMillis()
            val prefs = cachedPrefs ?: dbReader.readPrefs(applicationContext).also { cachedPrefs = it }
            val entriesJson = HoshiBridge.lookupJson(
                query,
                maxResults = prefs.maximumSearchResults,
                maxTerms = prefs.maximumTerms
            )
            val stylesJson = HoshiBridge.getStylesJson()
            val elapsed = System.currentTimeMillis() - t0
            Log.d(TAG, "lookup: ${elapsed}ms query=$query")

            runOnUiThread { injectResults(entriesJson, stylesJson, prefs) }
        }
    }

    private fun injectResults(
        entriesJson: String,
        stylesJson: String,
        prefs: PopupDbReader.PopupPrefs
    ) {
        val isDark = prefs.isDarkMode
        val theme = if (isDark) "dark" else "light"
        val safeDictColor = prefs.overrideDictColor?.takeIf {
            it.matches(Regex("^(rgb\\(\\d{1,3},\\s*\\d{1,3},\\s*\\d{1,3}\\)|#[0-9a-fA-F]{3,8})$"))
        }
        val bgColor = safeDictColor ?: if (isDark) "rgb(30,30,30)" else "rgb(255,255,255)"
        val textColor = if (isDark) "rgb(230,230,230)" else "rgb(30,30,30)"
        val collapsedJson = JSONArray(prefs.collapsedDictNames).toString()
        val safeCustomCss = try {
            org.json.JSONObject(prefs.customDictCSS).toString()
        } catch (_: Exception) { "{}" }

        val js = """
            document.documentElement.setAttribute('data-theme', '$theme');
            document.documentElement.style.setProperty('--text-color', '$textColor');
            document.documentElement.style.setProperty('--background-color', '$bgColor');
            window.deduplicatePitchAccents = ${prefs.deduplicatePitch};
            window.harmonicFrequency = ${prefs.harmonicFrequency};
            window.showExpressionTags = ${prefs.showExpressionTags};
            window.collapseDictionaries = ${prefs.collapseDictionaries};
            window.collapsedDictionaryNames = $collapsedJson;
            window.needsAudio = false;
            try { window.lookupEntries = $entriesJson; } catch(e) {
                console.error('[popup] parse error', e);
                window.lookupEntries = [];
            }
            window.dictionaryStyles = $stylesJson;
            window.globalDictCSS = ${escapeForJs(prefs.globalDictCSS)};
            window.customDictCSS = $safeCustomCss;
            window.renderPopup();
        """.trimIndent()

        webView.evaluateJavascript(js, null)
    }

    private fun escapeForJs(s: String): String {
        return "\"" + s.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r") + "\""
    }

    private fun handleMediaRequest(url: Uri): WebResourceResponse? {
        val dictName: String
        val mediaPath: String
        if (url.scheme == "image") {
            dictName = url.getQueryParameter("dictionary") ?: return null
            mediaPath = normalizeMediaPath(url.getQueryParameter("path") ?: return null)
        } else {
            dictName = url.getQueryParameter("dictionary") ?: return null
            mediaPath = normalizeMediaPath(Uri.decode(url.host ?: return null))
        }
        if (dictName.isEmpty() || mediaPath.isEmpty()) return null

        val data = HoshiBridge.getMedia(dictName, mediaPath) ?: return notFoundResponse()
        val mimeType = when {
            url.scheme == "dictmedia" -> "text/css"
            mediaPath.endsWith(".png") -> "image/png"
            mediaPath.endsWith(".jpg") || mediaPath.endsWith(".jpeg") -> "image/jpeg"
            mediaPath.endsWith(".svg") -> "image/svg+xml"
            mediaPath.endsWith(".gif") -> "image/gif"
            mediaPath.endsWith(".webp") -> "image/webp"
            else -> "application/octet-stream"
        }
        val encoding = if (mimeType.startsWith("text/")) "utf-8" else null
        return WebResourceResponse(mimeType, encoding, ByteArrayInputStream(data))
    }

    private fun normalizeMediaPath(path: String): String {
        return path.trim().replace('\\', '/').replaceFirst(Regex("^/+"), "")
    }

    private fun notFoundResponse(): WebResourceResponse {
        return WebResourceResponse(
            "text/plain", "utf-8", 404, "Not Found",
            emptyMap(), ByteArrayInputStream(ByteArray(0))
        )
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent == null) return null
        intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.let { return it }
        intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let { return it }
        intent.data?.let { uri ->
            if (uri.scheme == "hibiki" && uri.host == "lookup") {
                uri.getQueryParameter("word")?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            }
        }
        return null
    }

    private fun applyPopupWindowSize() {
        val dm = resources.displayMetrics
        val density = dm.density
        val screenWidth = dm.widthPixels
        val screenHeight = dm.heightPixels

        val maxWidthPx = (520 * density).toInt()
        val maxHeightPx = (640 * density).toInt()
        val width = minOf((screenWidth * 0.92f).toInt(), maxWidthPx)
        val height = minOf((screenHeight * 0.70f).toInt(), maxHeightPx)

        window.attributes = window.attributes.apply {
            this.width = width
            this.height = height
            this.gravity = Gravity.CENTER
            this.dimAmount = 0f
        }
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
    }

    private fun configureWebViewDataDir() {
        if (webViewDataDirConfigured) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WebView.setDataDirectorySuffix("popup")
        }
        webViewDataDirConfigured = true
    }

    inner class PopupJsInterface {
        @JavascriptInterface
        fun tapOutside() {
            runOnUiThread { finish() }
        }

        @JavascriptInterface
        fun scrolledToBottom() {
            // Native popup doesn't support load-more (all results loaded at once)
        }

        @JavascriptInterface
        fun textSelected(argsJson: String) {
            try {
                val arr = JSONArray(argsJson)
                val text = arr.optString(0, "")
                if (text.isNotEmpty()) {
                    runOnUiThread {
                        searchField.setText(text)
                        performSearch(text)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "textSelected parse error", e)
            }
        }

        @JavascriptInterface
        fun onLinkClick(query: String) {
            if (query.isNotEmpty()) {
                runOnUiThread {
                    searchField.setText(query)
                    performSearch(query)
                }
            }
        }

        @JavascriptInterface
        fun openLink(url: String) {
            try {
                val uri = Uri.parse(url)
                val intent = Intent(Intent.ACTION_VIEW, uri)
                startActivity(intent)
            } catch (e: Exception) {
                Log.e(TAG, "openLink failed", e)
            }
        }

        @JavascriptInterface
        fun mineEntry(fieldsJson: String): Boolean {
            // AnkiDroid mining stub — full implementation requires deck/model config
            // which lives in Dart preferences. For now, log the request.
            Log.d(TAG, "mineEntry requested: $fieldsJson")
            return false
        }
    }
}
