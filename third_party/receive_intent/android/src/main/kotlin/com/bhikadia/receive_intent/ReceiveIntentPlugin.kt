package com.bhikadia.receive_intent

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject


/** ReceiveIntentPlugin */
class ReceiveIntentPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    /// The MethodChannel that will the communication between Flutter and native Android
    ///
    /// This local reference serves to register the plugin with the Flutter Engine and unregister it
    /// when the Flutter Engine is detached from the Activity
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventSink? = null

    private lateinit var context: Context
    private var activity: Activity? = null;


    private var initialIntentMap: Map<String, Any?>? = null
    private var latestIntentMap: Map<String, Any?>? = null
    private var initialIntent = true

    private fun handleIntent(intent: Intent, fromPackageName: String?) {
        //Log.e("ReceiveIntentPlugin", "intent: $intent")
        //Log.e("ReceiveIntentPlugin", "fromPackageName: $fromPackageName")
        val intentMap = mapOf<String, Any?>(
                "fromPackageName" to fromPackageName,
                "fromSignatures" to fromPackageName?.let { getApplicationSignature(context, it) },
                "action" to intent.action,
                "data" to intent.dataString,
                "categories" to intent.categories?.toList(),
                "extra" to intent.extras?.let { bundleToJSON(it).toString() }
        )
        //Log.e("ReceiveIntentPlugin", "intentMap: $intentMap")
        if (initialIntent) {
            initialIntentMap = intentMap
            initialIntent = false
        }
        latestIntentMap = intentMap
        eventSink?.success(latestIntentMap)
    }

    private fun setResult(result: Result, resultCode: Int?, action: String?, data: String?, shouldFinish: Boolean?) {
        if (resultCode != null) {
            if (data == null) {
                activity?.setResult(resultCode)
            } else {
                val json = JSONObject(data)
                val intent = Intent(action).apply {
                    putExtras(jsonToBundle(json))
                }
                activity?.setResult(resultCode, intent)
            }
            if (shouldFinish ?: false) {
                activity?.finish()
            }
            return result.success(null)
        }
        result.error("InvalidArg", "resultCode can not be null", null)
    }


    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "receive_intent")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "receive_intent/event")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "getInitialIntent" -> {
                result.success(initialIntentMap)
            }
            "setResult" -> {
                setResult(result, call.argument("resultCode"), call.argument("action"), call.argument("data"), call.argument("shouldFinish"))
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addOnNewIntentListener(fun(intent: Intent?): Boolean {
            intent?.let { handleIntent(it, binding.activity.callingActivity?.packageName) }
            return false;
        })
        handleIntent(binding.activity.intent, binding.activity.callingActivity?.packageName)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addOnNewIntentListener(fun(intent: Intent?): Boolean {
            intent?.let { handleIntent(it, binding.activity.callingActivity?.packageName) }
            return false;
        })
        handleIntent(binding.activity.intent, binding.activity.callingActivity?.packageName)
    }

    override fun onDetachedFromActivity() {
        activity = null;
    }
}
