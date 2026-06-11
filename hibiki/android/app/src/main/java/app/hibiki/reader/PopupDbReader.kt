package app.hibiki.reader

import android.content.Context
import android.content.res.Configuration
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * Read-only SQLite access to the Drift database from the `:popup` process,
 * which has no Flutter engine and therefore no Drift instance.
 *
 * This is a parallel read path that MUST stay in sync with the Drift schema in
 * `packages/hibiki_core/lib/src/database/`. The column names below mirror the
 * Drift table definitions; [EXPECTED_SCHEMA_VERSION] guards against silent
 * divergence when a migration bumps the schema.
 */
class PopupDbReader {
    companion object {
        private const val TAG = "PopupDbReader"

        /**
         * MUST match `HibikiDatabase.schemaVersion` in
         * `packages/hibiki_core/lib/src/database/database.dart`.
         * Bump this in lockstep with any Drift migration.
         */
        const val EXPECTED_SCHEMA_VERSION = 13
    }

    /** Named queries mirroring the Drift schema. */
    private object PopupQueries {
        // Corresponds to DictionaryMetadataTable in tables.dart
        // (columns: name, type, hidden_languages_json, "order").
        const val DICT_PATHS =
            "SELECT name, type, hidden_languages_json, \"order\" " +
                "FROM dictionary_metadata ORDER BY \"order\" ASC"

        // Corresponds to DictionaryMetadataTable in tables.dart
        // (columns: name, collapsed_languages_json).
        const val DICT_COLLAPSED =
            "SELECT name, collapsed_languages_json FROM dictionary_metadata"

        // Corresponds to PreferencesTable in tables.dart (columns: key, value).
        const val PREFERENCES = "SELECT key, value FROM preferences"
    }

    data class DictPath(val path: String, val type: String)

    data class PopupPrefs(
        val deduplicatePitch: Boolean = false,
        val harmonicFrequency: Boolean = false,
        val collapseDictionaries: Boolean = false,
        val showExpressionTags: Boolean = false,
        val globalDictCSS: String = "",
        val customDictCSS: String = "{}",
        val targetLanguage: String = "ja",
        val isDarkMode: Boolean = false,
        val overrideDictColor: String? = null,
        val collapsedDictNames: List<String> = emptyList(),
        val maximumTerms: Int = 100,
        val maximumSearchResults: Int = 16,
    )

    private fun isHiddenForLanguage(hiddenJson: String?, lang: String): Boolean {
        if (hiddenJson.isNullOrEmpty()) return false
        return try {
            val arr = org.json.JSONArray(hiddenJson)
            for (i in 0 until arr.length()) {
                if (arr.getString(i) == lang) return true
            }
            false
        } catch (_: Exception) { false }
    }

    private fun dbPath(context: Context): String {
        return File(context.filesDir, "hibiki.db").absolutePath
    }

    private fun dictionaryResourceDir(context: Context): String {
        val docsDir = context.getDir("flutter", Context.MODE_PRIVATE)
        return File(docsDir, "dictionaryResources").absolutePath
    }

    /**
     * Opens the Drift database read-only, or returns null if it does not exist.
     * Logs a warning when the on-disk schema version diverges from
     * [EXPECTED_SCHEMA_VERSION] so a stale read path surfaces in logs instead of
     * returning silently wrong data.
     */
    private fun openDb(context: Context): SQLiteDatabase? {
        val dbFile = File(dbPath(context))
        if (!dbFile.exists()) {
            Log.w(TAG, "DB not found: ${dbFile.absolutePath}")
            return null
        }
        val db = SQLiteDatabase.openDatabase(
            dbFile.absolutePath, null,
            SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
        )
        if (db.version != EXPECTED_SCHEMA_VERSION) {
            Log.w(
                TAG,
                "Schema mismatch: expected $EXPECTED_SCHEMA_VERSION, got ${db.version}; " +
                    "popup queries may be stale"
            )
        }
        return db
    }

    fun readDictionaryPaths(context: Context, targetLanguage: String = "ja"): List<DictPath> {
        val paths = mutableListOf<DictPath>()
        val resDir = dictionaryResourceDir(context)
        var db: SQLiteDatabase? = null
        try {
            db = openDb(context) ?: return paths
            val cursor = db.rawQuery(PopupQueries.DICT_PATHS, null)
            cursor.use {
                while (it.moveToNext()) {
                    val name = it.getString(0)
                    val type = it.getString(1)
                    val hiddenJson = it.getString(2)
                    val dictDir = File(resDir, name)
                    if (!dictDir.exists()) continue

                    if (isHiddenForLanguage(hiddenJson, targetLanguage)) continue

                    // Route the kanji type to its own bucket so the popup
                    // process feeds kanji dictionaries to nativeAddKanjiDict and a
                    // single-character lookup resolves through query_kanji. This
                    // activates the (previously dormant) "kanji" branch in
                    // HoshiBridge.kt (TODO-094 S4). Unknown types still fall back
                    // to "term" to fail safe.
                    val mappedType = when (type) {
                        "term" -> "term"
                        "kanji" -> "kanji"
                        "frequency" -> "frequency"
                        "pitch" -> "pitch"
                        else -> "term"
                    }
                    paths.add(DictPath(dictDir.absolutePath, mappedType))
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "readDictionaryPaths failed", e)
        } finally {
            db?.close()
        }
        return paths
    }

    fun readCollapsedDictNames(context: Context, targetLang: String): List<String> {
        val collapsed = mutableListOf<String>()
        var db: SQLiteDatabase? = null
        try {
            db = openDb(context) ?: return collapsed
            val cursor = db.rawQuery(PopupQueries.DICT_COLLAPSED, null)
            cursor.use {
                while (it.moveToNext()) {
                    val name = it.getString(0)
                    val json = it.getString(1)
                    try {
                        val arr = org.json.JSONArray(json)
                        for (i in 0 until arr.length()) {
                            if (arr.getString(i) == targetLang) {
                                collapsed.add(name)
                                break
                            }
                        }
                    } catch (_: Exception) {}
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "readCollapsedDictNames failed", e)
        } finally {
            db?.close()
        }
        return collapsed
    }

    fun readPrefs(context: Context): PopupPrefs {
        val prefs = mutableMapOf<String, String>()
        var db: SQLiteDatabase? = null
        try {
            db = openDb(context) ?: return PopupPrefs()
            val cursor = db.rawQuery(PopupQueries.PREFERENCES, null)
            cursor.use {
                while (it.moveToNext()) {
                    prefs[it.getString(0)] = it.getString(1)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "readPrefs failed", e)
        } finally {
            db?.close()
        }

        val targetLang = prefs["target_language"] ?: "ja"
        return PopupPrefs(
            deduplicatePitch = prefs["deduplicate_pitch_accents"] == "true",
            harmonicFrequency = prefs["harmonic_frequency"] == "true",
            collapseDictionaries = prefs["collapse_dictionaries"] == "true",
            showExpressionTags = prefs["show_expression_tags"] == "true",
            globalDictCSS = prefs["global_dict_css"] ?: "",
            customDictCSS = prefs["custom_dict_css"] ?: "{}",
            targetLanguage = targetLang,
            isDarkMode = when (prefs["brightness_mode"]) {
                "dark" -> true
                "light" -> false
                else -> (context.resources.configuration.uiMode and
                         Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
            },
            overrideDictColor = prefs["dictionary_color"],
            collapsedDictNames = readCollapsedDictNames(context, targetLang),
            maximumTerms = (prefs["maximum_terms"]?.toIntOrNull() ?: 100),
            maximumSearchResults = (prefs["maximum_dictionary_search_results"]?.toIntOrNull() ?: 16),
        )
    }
}
