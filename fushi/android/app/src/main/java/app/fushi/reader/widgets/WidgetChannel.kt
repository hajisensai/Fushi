package app.fushi.reader.widgets

import android.content.Context
import android.util.Log
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.updateAll
import app.fushi.reader.constants.ChannelNames
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * `app.fushi.reader/widgets`: Flutter pushes the home-screen widget snapshot here.
 *
 * `updateSnapshot(json: String)` stores the JSON ([WidgetStore]) and re-renders every
 * placed widget. Contract and JSON shape: `lib/src/platform/widget_snapshot.dart`.
 */
object WidgetChannel {
    private const val TAG = "WidgetChannel"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val widgets: List<GlanceAppWidget> get() = WidgetRegistry.all

    @JvmStatic
    fun registerWith(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, ChannelNames.WIDGETS)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateSnapshot" -> {
                        val json = call.arguments as? String
                        if (json == null) {
                            result.error("bad_args", "updateSnapshot expects a JSON string", null)
                        } else {
                            WidgetStore.save(app, json)
                            refreshAll(app)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun refreshAll(context: Context) {
        scope.launch {
            for (widget in widgets) {
                try {
                    widget.updateAll(context)
                } catch (t: Throwable) {
                    // One broken widget must not stop the others from refreshing.
                    Log.w(TAG, "update failed for ${widget.javaClass.simpleName}", t)
                }
            }
        }
    }
}
