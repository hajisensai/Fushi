package app.fushi.reader.mihon

import android.app.Application
import androidx.preference.CheckBoxPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceGroup
import androidx.preference.PreferenceManager
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import eu.kanade.tachiyomi.source.ConfigurableSource

internal object MihonPreferenceBridge {
    private const val CONTEXT_KEY = "__mangatan_bridge_context__"

    fun applyAndRead(
        app: Application,
        source: ConfigurableSource,
        values: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> {
        val context = values.firstOrNull { item -> item["key"] == CONTEXT_KEY }
        val changedKey = context?.get("changedPreferenceKey")?.toString()
        val manager = PreferenceManager(app).apply {
            sharedPreferencesName = "source_${source.id}"
        }
        val screen = manager.createPreferenceScreen(app)
        source.setupPreferenceScreen(screen)
        values
            .filterNot { item -> item["key"] == CONTEXT_KEY }
            .forEach { item -> applyValue(source, screen, item, item["key"] == changedKey) }
        return flatten(screen).map { preference -> serialize(preference) }
    }

    fun apply(
        app: Application,
        source: ConfigurableSource,
        values: List<Map<String, Any?>>,
    ) {
        applyAndRead(app, source, values)
    }

    private fun applyValue(
        source: ConfigurableSource,
        screen: PreferenceScreen,
        item: Map<String, Any?>,
        notify: Boolean,
    ) {
        val key = item["key"]?.toString().orEmpty()
        if (key.isEmpty()) return
        val preference = screen.findPreference<Preference>(key)
        val shared = source.getSourcePreferences()
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
