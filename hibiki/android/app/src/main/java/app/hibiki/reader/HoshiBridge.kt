package app.hibiki.reader

import android.content.Context
import android.util.Log
import java.io.File

object HoshiBridge {
    private const val TAG = "HoshiBridge"

    @Volatile
    private var handle: Long = 0L

    @Volatile
    private var initialized = false

    init {
        System.loadLibrary("hoshidicts_jni")
    }

    @Synchronized
    fun initialize(context: Context, dbReader: PopupDbReader) {
        if (initialized) return

        handle = nativeCreate()
        if (handle == 0L) {
            Log.e(TAG, "nativeCreate returned null handle")
            return
        }

        val prefs = dbReader.readPrefs(context)
        val dictPaths = dbReader.readDictionaryPaths(context, prefs.targetLanguage)
        for ((path, type) in dictPaths) {
            when (type) {
                "term" -> nativeAddTermDict(handle, path)
                "frequency" -> nativeAddFreqDict(handle, path)
                "pitch" -> nativeAddPitchDict(handle, path)
                // S4: PopupDbReader now emits a real "kanji" type for the
                // kanji bucket, so this branch routes kanji dictionaries to the
                // native kanji index (TODO-094 S4).
                "kanji" -> nativeAddKanjiDict(handle, path)
            }
        }

        loadTransforms(context)
        initialized = true
        Log.d(TAG, "initialized with ${dictPaths.size} dictionaries")
    }

    private fun loadTransforms(context: Context) {
        val assets = context.assets
        val transformDir = "flutter_assets/assets/transforms"
        try {
            val files = assets.list(transformDir) ?: return
            for (file in files) {
                if (!file.endsWith(".json")) continue
                val json = assets.open("$transformDir/$file").bufferedReader().use { it.readText() }
                nativeLoadTransforms(handle, json)
            }
        } catch (e: Exception) {
            Log.e(TAG, "loadTransforms failed", e)
        }
    }

    @Synchronized
    fun lookupJson(
        text: String,
        maxResults: Int = 16,
        scanLength: Int = 16,
        maxTerms: Int = 100
    ): String {
        if (handle == 0L) return "[]"
        return nativeLookupJson(handle, text, maxResults, scanLength, maxTerms)
    }

    @Synchronized
    fun queryKanjiJson(character: String): String {
        if (handle == 0L) return "[]"
        return nativeQueryKanjiJson(handle, character)
    }

    @Synchronized
    fun getStylesJson(): String {
        if (handle == 0L) return "{}"
        return nativeGetStylesJson(handle)
    }

    @Synchronized
    fun getMedia(dictName: String, mediaPath: String): ByteArray? {
        if (handle == 0L) return null
        return nativeGetMedia(handle, dictName, mediaPath)
    }

    @Synchronized
    fun destroy() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0L
            initialized = false
        }
    }

    // JNI declarations
    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeAddTermDict(handle: Long, path: String)
    private external fun nativeAddFreqDict(handle: Long, path: String)
    private external fun nativeAddPitchDict(handle: Long, path: String)
    private external fun nativeAddKanjiDict(handle: Long, path: String)
    private external fun nativeLoadTransforms(handle: Long, json: String)
    private external fun nativeLookupJson(
        handle: Long, text: String,
        maxResults: Int, scanLength: Int, maxTerms: Int
    ): String
    private external fun nativeQueryKanjiJson(handle: Long, character: String): String
    private external fun nativeGetStylesJson(handle: Long): String
    private external fun nativeGetMedia(
        handle: Long, dictName: String, mediaPath: String
    ): ByteArray?
}
