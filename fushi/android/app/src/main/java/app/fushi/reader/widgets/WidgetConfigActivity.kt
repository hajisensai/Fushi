package app.fushi.reader.widgets

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import androidx.datastore.preferences.core.Preferences
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.getAppWidgetState
import androidx.glance.state.PreferencesGlanceStateDefinition
import app.fushi.reader.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Per-widget settings, shown when a widget is added and from "Reconfigure" on Android 12+.
 * Plain Views, no Flutter. Values go into the instance's Glance preferences state
 * ([WidgetPrefs]) keyed by appWidgetId, so every placed widget is independent.
 */
class WidgetConfigActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    private lateinit var themeGroup: RadioGroup
    private var privacy: RadioGroup? = null
    private var vocabSource: RadioGroup? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Back / cancel must leave the host with RESULT_CANCELED so it drops a half-added widget.
        setResult(RESULT_CANCELED)
        appWidgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        val provider = AppWidgetManager.getInstance(this).getAppWidgetInfo(appWidgetId)?.provider?.className.orEmpty()
        val widget = WidgetRegistry.forReceiver(provider)
        val isVocab = provider.endsWith("VocabReceiver")
        val hasPrivacy = isVocab || provider.endsWith("ContinueReceiver") || provider.endsWith("ShelfReceiver")

        scope.launch {
            val current = try {
                val id = GlanceAppWidgetManager(this@WidgetConfigActivity).getGlanceIdBy(appWidgetId)
                WidgetConfig.from(getAppWidgetState<Preferences>(this@WidgetConfigActivity, PreferencesGlanceStateDefinition, id))
            } catch (_: Throwable) {
                WidgetConfig()
            }
            build(current, hasPrivacy, isVocab) { save(widget) }
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun heading(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 14f
        setPadding(0, dp(20), 0, dp(4))
    }

    private fun group(options: List<Pair<String, Int>>, selected: String): RadioGroup = RadioGroup(this).apply {
        orientation = RadioGroup.VERTICAL
        options.forEach { (value, label) ->
            addView(
                RadioButton(this@WidgetConfigActivity).apply {
                    id = View.generateViewId()
                    text = getString(label)
                    tag = value
                    minHeight = dp(48)
                    isChecked = value == selected
                },
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }
    }

    private fun RadioGroup.value(default: String): String =
        findViewById<RadioButton>(checkedRadioButtonId)?.tag as? String ?: default

    private fun build(current: WidgetConfig, hasPrivacy: Boolean, isVocab: Boolean, onSave: () -> Unit) {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        column.addView(TextView(this).apply {
            text = getString(R.string.widget_config_title)
            textSize = 22f
        })
        column.addView(heading(getString(R.string.widget_config_theme)))
        themeGroup = group(
            listOf(
                "system" to R.string.widget_config_theme_system,
                "light" to R.string.widget_config_theme_light,
                "dark" to R.string.widget_config_theme_dark,
            ),
            current.theme,
        )
        column.addView(themeGroup)
        if (hasPrivacy) {
            column.addView(heading(getString(R.string.widget_config_privacy)))
            privacy = group(
                listOf(
                    "follow" to R.string.widget_config_privacy_follow,
                    "show" to R.string.widget_config_privacy_show,
                    "hide" to R.string.widget_config_privacy_hide,
                ),
                current.privacy,
            ).also { column.addView(it) }
        }
        if (isVocab) {
            column.addView(heading(getString(R.string.widget_config_vocab_source)))
            vocabSource = group(
                listOf(
                    "all" to R.string.widget_config_vocab_all,
                    "mined" to R.string.widget_config_vocab_mined,
                    "favorite" to R.string.widget_config_vocab_favorite,
                ),
                current.vocabSource,
            ).also { column.addView(it) }
        }
        column.addView(
            Button(this).apply {
                text = getString(R.string.widget_config_save)
                minHeight = dp(48)
                setOnClickListener { onSave() }
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(24)
            },
        )
        setContentView(ScrollView(this).apply { addView(column) })
    }

    private fun save(widget: androidx.glance.appwidget.GlanceAppWidget?) {
        val themeValue = themeGroup.value("system")
        val privacyValue = privacy?.value("follow")
        val sourceValue = vocabSource?.value("all")
        scope.launch {
            try {
                val id = GlanceAppWidgetManager(this@WidgetConfigActivity).getGlanceIdBy(appWidgetId)
                updateWidgetPrefs(this@WidgetConfigActivity, widget ?: WidgetRegistry.all.first(), id) { p ->
                    p[WidgetPrefs.THEME] = themeValue
                    if (privacyValue != null) p[WidgetPrefs.PRIVACY] = privacyValue
                    if (sourceValue != null) {
                        p[WidgetPrefs.VOCAB_SOURCE] = sourceValue
                        // A different pool makes the old "next" offset meaningless.
                        p[WidgetPrefs.VOCAB_OFFSET] = 0
                    }
                }
            } catch (_: Throwable) {
                // Saving failed (e.g. widget removed meanwhile): still close cleanly.
            }
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
            finish()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
