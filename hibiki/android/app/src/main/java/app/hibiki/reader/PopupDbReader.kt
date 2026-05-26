package app.hibiki.reader

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import org.json.JSONObject
import java.io.File

class PopupDbReader {
    companion object {
        private const val TAG = "PopupDbReader"
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
        val supportDir = context.filesDir.parentFile?.resolve("app_flutter")
            ?: context.filesDir
        return File(supportDir, "hibiki.db").absolutePath
    }

    private fun dictionaryResourceDir(context: Context): String {
        val docsDir = File(context.filesDir.parentFile, "app_flutter")
        return File(docsDir, "dictionaryResources").absolutePath
    }

    fun readDictionaryPaths(context: Context, targetLanguage: String = "ja"): List<DictPath> {
        val paths = mutableListOf<DictPath>()
        val dbFile = File(dbPath(context))
        if (!dbFile.exists()) {
            Log.w(TAG, "DB not found: ${dbFile.absolutePath}")
            return paths
        }

        val resDir = dictionaryResourceDir(context)
        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(
                dbFile.absolutePath, null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
            )
            val cursor = db.rawQuery(
                "SELECT name, type, hidden_languages_json, \"order\" " +
                        "FROM dictionary_metadata ORDER BY \"order\" ASC",
                null
            )
            cursor.use {
                while (it.moveToNext()) {
                    val name = it.getString(0)
                    val type = it.getString(1)
                    val hiddenJson = it.getString(2)
                    val dictDir = File(resDir, name)
                    if (!dictDir.exists()) continue

                    if (isHiddenForLanguage(hiddenJson, targetLanguage)) continue

                    val mappedType = when (type) {
                        "term", "kanji" -> "term"
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
        val dbFile = File(dbPath(context))
        if (!dbFile.exists()) return collapsed

        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(
                dbFile.absolutePath, null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
            )
            val cursor = db.rawQuery(
                "SELECT name, collapsed_languages_json FROM dictionary_metadata", null
            )
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
        val dbFile = File(dbPath(context))
        if (!dbFile.exists()) return PopupPrefs()

        val prefs = mutableMapOf<String, String>()
        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(
                dbFile.absolutePath, null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
            )
            val cursor = db.rawQuery("SELECT key, value FROM preferences", null)
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
            isDarkMode = prefs["theme_mode"] == "dark",
            overrideDictColor = prefs["dictionary_color"],
            collapsedDictNames = readCollapsedDictNames(context, targetLang),
            maximumTerms = (prefs["maximum_terms"]?.toIntOrNull() ?: 100),
            maximumSearchResults = (prefs["maximum_dictionary_search_results"]?.toIntOrNull() ?: 16),
        )
    }
}
