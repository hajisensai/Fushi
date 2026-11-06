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
import androidx.preference.TwoStatePreference
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.ConfigurableAnimeSource
import eu.kanade.tachiyomi.source.ConfigurableSource

internal object MihonPreferenceBridge {
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
        val plan = MihonPreferencePlan.of(values)
        // 快照先落 store，再建 screen：偏好对象挂进 screen 时读一次持久值（反馈 Njruv6JSaL，
        // 旧顺序 setup 在前，回传的永远是上一拍的值）。
        if (plan.snapshot.isNotEmpty()) {
            val editor = shared.edit()
            plan.snapshot.forEach { (key, value) -> put(editor, key, value) }
            editor.commit()
        }
        val changed = plan.changed ?: return readScreen(app, sourceId, setup)
        val screen = buildScreen(app, sourceId, setup)
        screen.findPreference<Preference>(changed.first)?.let { preference ->
            applyChange(preference, changed.second)
        }
        // 重新建一遍再读：listener 拒收时可能已自己规整并持久化（桌面 sidecar 同一假设），
        // 读回的只认 store 里的真值。
        return readScreen(app, sourceId, setup)
    }

    private fun buildScreen(
        app: Application,
        sourceId: Long,
        setup: (PreferenceScreen) -> Unit,
    ): PreferenceScreen {
        val manager = PreferenceManager(app).apply {
            sharedPreferencesName = "source_$sourceId"
        }
        val screen = manager.createPreferenceScreen(app)
        setup(screen)
        return screen
    }

    private fun readScreen(
        app: Application,
        sourceId: Long,
        setup: (PreferenceScreen) -> Unit,
    ): List<Map<String, Any?>> = flatten(buildScreen(app, sourceId, setup)).map { preference ->
        serialize(preference)
    }

    fun apply(
        app: Application,
        source: ConfigurableSource,
        values: List<Map<String, Any?>>,
    ) {
        writeSnapshot(source.getSourcePreferences(), values)
    }

    fun apply(
        app: Application,
        source: ConfigurableAnimeSource,
        values: List<Map<String, Any?>>,
    ) {
        writeSnapshot(source.getSourcePreferences(), values)
    }

    /** 非偏好请求（列表 / 搜索 / 取流…）只需要让源读到快照，不建偏好屏。 */
    private fun writeSnapshot(shared: SharedPreferences, values: List<Map<String, Any?>>) {
        val plan = MihonPreferencePlan.of(values)
        if (plan.snapshot.isEmpty()) return
        val editor = shared.edit()
        plan.snapshot.forEach { (key, value) -> put(editor, key, value) }
        editor.commit()
    }

    private fun put(editor: SharedPreferences.Editor, key: String, value: Any) {
        when (value) {
            is Boolean -> editor.putBoolean(key, value)
            is String -> editor.putString(key, value)
            is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
        }
    }

    /**
     * 用户在偏好屏上改了一项：先问 change listener，收下才经偏好对象自己的 setter 保存
     * （setter 经 PreferenceManager 持久化，对象与 store 同步）。与桌面
     * `MihonInvoker.applyPreferenceChange` 同一语义。
     */
    private fun applyChange(preference: Preference, value: Any) {
        if (!preference.callChangeListener(value)) return
        when (preference) {
            is EditTextPreference -> (value as? String)?.let { preference.text = it }
            is ListPreference -> (value as? String)?.let { preference.value = it }
            is MultiSelectListPreference -> (value as? Set<*>)?.let { set ->
                preference.values = set.filterIsInstance<String>().toSet()
            }
            is TwoStatePreference -> (value as? Boolean)?.let { preference.isChecked = it }
        }
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
