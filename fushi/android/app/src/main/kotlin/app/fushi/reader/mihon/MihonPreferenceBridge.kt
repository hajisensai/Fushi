package app.fushi.reader.mihon

import android.app.Application
import android.content.SharedPreferences
import androidx.preference.CheckBoxPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceGroup
import androidx.preference.PreferenceManager
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.ConfigurableAnimeSource
import eu.kanade.tachiyomi.source.ConfigurableSource

internal object MihonPreferenceBridge {
    private const val CONTEXT_KEY = "__mangatan_bridge_context__"

    fun applyAndRead(
        app: Application,
        source: ConfigurableSource,
        values: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> = applyAndRead(
        app,
        sourceId = source.id,
        setup = source::setupPreferenceScreen,
        shared = source.getSourcePreferences(),
        values = values,
    )

    /** Aniyomi 的可配置源：同一套偏好屏 / SharedPreferences 约定，只是接口不同。 */
    fun applyAndRead(
        app: Application,
        source: ConfigurableAnimeSource,
        values: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> = applyAndRead(
        app,
        sourceId = (source as AnimeSource).id,
        setup = source::setupPreferenceScreen,
        shared = source.getSourcePreferences(),
        values = values,
    )

    private fun applyAndRead(
        app: Application,
        sourceId: Long,
        setup: (PreferenceScreen) -> Unit,
        shared: SharedPreferences,
        values: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> {
        val context = values.firstOrNull { item -> item["key"] == CONTEXT_KEY }
        val changedKey = context?.get("changedPreferenceKey")?.toString()
        val manager = PreferenceManager(app).apply {
            sharedPreferencesName = "source_$sourceId"
        }
        val screen = manager.createPreferenceScreen(app)
        setup(screen)
        values
            .filterNot { item -> item["key"] == CONTEXT_KEY }
            .forEach { item -> applyValue(shared, screen, item, item["key"] == changedKey) }
        return flatten(screen).map { preference -> serialize(preference) }
    }

    fun apply(
        app: Application,
        source: ConfigurableSource,
        values: List<Map<String, Any?>>,
    ) {
        applyAndRead(app, source, values)
    }

    fun apply(
        app: Application,
        source: ConfigurableAnimeSource,
        values: List<Map<String, Any?>>,
    ) {
        applyAndRead(app, source, values)
    }

    private fun applyValue(
        shared: SharedPreferences,
        screen: PreferenceScreen,
        item: Map<String, Any?>,
        notify: Boolean,
    ) {
        val key = item["key"]?.toString().orEmpty()
        if (key.isEmpty()) return
        val preference = screen.findPreference<Preference>(key)
        val editor = shared.edit()
        val value: Any? = when {
            item["checkBoxPreference"] is Map<*, *> ->
                (item["checkBoxPreference"] as Map<*, *>)["value"] as? Boolean
            item["switchPreferenceCompat"] is Map<*, *> ->
                (item["switchPreferenceCompat"] as Map<*, *>)["value"] as? Boolean
            item["editTextPreference"] is Map<*, *> ->
                (item["editTextPreference"] as Map<*, *>)["value"]?.toString()
            item["listPreference"] is Map<*, *> -> {
                val index = ((item["listPreference"] as Map<*, *>)["valueIndex"] as? Number)
                    ?.toInt() ?: 0
                (preference as? ListPreference)?.entryValues?.getOrNull(index)?.toString()
            }
            item["multiSelectListPreference"] is Map<*, *> ->
                ((item["multiSelectListPreference"] as Map<*, *>)["values"] as? List<*>)
                    ?.map { entry -> entry.toString() }
                    ?.toSet()
            else -> null
        }
        if (value == null || (notify && preference?.callChangeListener(value) == false)) return
        when (value) {
            is Boolean -> editor.putBoolean(key, value)
            is String -> editor.putString(key, value)
            is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
        }
        editor.commit()
    }

    private fun flatten(group: PreferenceGroup): List<Preference> = buildList {
        for (index in 0 until group.preferenceCount) {
            val preference = group.getPreference(index)
            if (preference is PreferenceGroup) {
                addAll(flatten(preference))
            } else {
                add(preference)
            }
        }
    }

    private fun serialize(preference: Preference): Map<String, Any?> {
        val key = preference.key.orEmpty()
        val common = mutableMapOf<String, Any?>(
            "title" to (preference.title?.toString() ?: key),
            "summary" to (preference.summary?.toString() ?: ""),
        )
        val payloadKey = when (preference) {
            is CheckBoxPreference -> {
                common["value"] = preference.isChecked
                "checkBoxPreference"
            }
            is SwitchPreferenceCompat -> {
                common["value"] = preference.isChecked
                "switchPreferenceCompat"
            }
            is EditTextPreference -> {
                common["value"] = preference.text.orEmpty()
                "editTextPreference"
            }
            is ListPreference -> {
                common["entries"] = preference.entries.orEmpty().map { it.toString() }
                common["entryValues"] = preference.entryValues.orEmpty().map { it.toString() }
                common["valueIndex"] = preference.findIndexOfValue(preference.value).coerceAtLeast(0)
                "listPreference"
            }
            is MultiSelectListPreference -> {
                common["entries"] = preference.entries.orEmpty().map { it.toString() }
                common["entryValues"] = preference.entryValues.orEmpty().map { it.toString() }
                common["values"] = preference.values.toList()
                "multiSelectListPreference"
            }
            else -> "unsupportedPreference"
        }
        return mapOf("key" to key, payloadKey to common)
    }
}
