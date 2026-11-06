/*
 * Copyright (c) 2018-2022, 2026 Taner Sener
 *
 * This file is part of FFmpegKitNext.
 *
 * FFmpegKitNext is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FFmpegKitNext is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General License for more details.
 *
 * You should have received a copy of the GNU Lesser General License
 * along with FFmpegKitNext. If not, see <http://www.gnu.org/licenses/>.
 */

package com.arthenica.ffmpegkit.flutter;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.util.Log;

import androidx.activity.result.ActivityResult;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.ActivityResultRegistryOwner;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.arthenica.ffmpegkit.AbiDetect;
import com.arthenica.ffmpegkit.AbstractSession;
import com.arthenica.ffmpegkit.FFmpegKit;
import com.arthenica.ffmpegkit.FFmpegKitConfig;
import com.arthenica.ffmpegkit.FFmpegKitInputBuffer;
import com.arthenica.ffmpegkit.FFmpegKitOutputBuffer;
import com.arthenica.ffmpegkit.FFmpegKitStreamInput;
import com.arthenica.ffmpegkit.FFmpegKitStreamOutput;
import com.arthenica.ffmpegkit.FFmpegSession;
import com.arthenica.ffmpegkit.FFprobeKit;
import com.arthenica.ffmpegkit.FFprobeSession;
import com.arthenica.ffmpegkit.Level;
import com.arthenica.ffmpegkit.LogRedirectionStrategy;
import com.arthenica.ffmpegkit.MediaInformation;
import com.arthenica.ffmpegkit.MediaInformationJsonParser;
import com.arthenica.ffmpegkit.MediaInformationSession;
import com.arthenica.ffmpegkit.Packages;
import com.arthenica.ffmpegkit.ReturnCode;
import com.arthenica.ffmpegkit.Session;
import com.arthenica.ffmpegkit.SessionState;
import com.arthenica.ffmpegkit.Signal;
import com.arthenica.ffmpegkit.Statistics;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

public class FFmpegKitFlutterPlugin implements FlutterPlugin, ActivityAware, MethodCallHandler, EventChannel.StreamHandler, PluginRegistry.ActivityResultListener {

    public static final String LIBRARY_NAME = "ffmpeg-kit-flutter";
    public static final String LIBRARY_VERSION = "9.0.0";
    public static final String PLATFORM_NAME = "android";

    private static final String METHOD_CHANNEL = "flutter.arthenica.com/ffmpeg_kit";
    private static final String EVENT_CHANNEL = "flutter.arthenica.com/ffmpeg_kit_event";

    // LOG CLASS
    public static final String KEY_LOG_SESSION_ID = "sessionId";
    public static final String KEY_LOG_LEVEL = "level";
    public static final String KEY_LOG_MESSAGE = "message";

    // STATISTICS CLASS
    public static final String KEY_STATISTICS_SESSION_ID = "sessionId";
    public static final String KEY_STATISTICS_VIDEO_FRAME_NUMBER = "videoFrameNumber";
    public static final String KEY_STATISTICS_VIDEO_FPS = "videoFps";
    public static final String KEY_STATISTICS_VIDEO_QUALITY = "videoQuality";
    public static final String KEY_STATISTICS_SIZE = "size";
    public static final String KEY_STATISTICS_TIME = "time";
    public static final String KEY_STATISTICS_BITRATE = "bitrate";
    public static final String KEY_STATISTICS_SPEED = "speed";

    // SESSION CLASS
    public static final String KEY_SESSION_ID = "sessionId";
    public static final String KEY_SESSION_CREATE_TIME = "createTime";
    public static final String KEY_SESSION_START_TIME = "startTime";
    public static final String KEY_SESSION_COMMAND = "command";
    public static final String KEY_SESSION_TYPE = "type";
    public static final String KEY_SESSION_MEDIA_INFORMATION = "mediaInformation";

    // SESSION TYPE
    public static final int SESSION_TYPE_FFMPEG = 1;
    public static final int SESSION_TYPE_FFPROBE = 2;
    public static final int SESSION_TYPE_MEDIA_INFORMATION = 3;

    // EVENTS
    public static final String EVENT_LOG_CALLBACK_EVENT = "FFmpegKitLogCallbackEvent";
    public static final String EVENT_STATISTICS_CALLBACK_EVENT = "FFmpegKitStatisticsCallbackEvent";
    public static final String EVENT_COMPLETE_CALLBACK_EVENT = "FFmpegKitCompleteCallbackEvent";
    public static final String EVENT_SESSION_DELETED_CALLBACK_EVENT = "FFmpegKitSessionDeletedCallbackEvent";

    // REQUEST CODES
    public static final int READABLE_REQUEST_CODE = 10000;
    public static final int WRITABLE_REQUEST_CODE = 20000;

    // ARGUMENT NAMES
    public static final String ARGUMENT_SESSION_ID = "sessionId";
    public static final String ARGUMENT_WAIT_TIMEOUT = "waitTimeout";
    public static final String ARGUMENT_ARGUMENTS = "arguments";
    public static final String ARGUMENT_FFPROBE_JSON_OUTPUT = "ffprobeJsonOutput";
    public static final String ARGUMENT_WRITABLE = "writable";

    private static final int asyncConcurrencyLimit = 10;
    private static final AtomicBoolean loadedLogged = new AtomicBoolean(false);

    private final AtomicBoolean logsEnabled;
    private final AtomicBoolean statisticsEnabled;
    private final ExecutorService asyncExecutorService;
    @Nullable
    private Object sessionDeleteListener;

    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private Result lastInitiatedIntentResult;
    private Context context;
    private Activity activity;
    private FlutterPluginBinding flutterPluginBinding;
    private ActivityPluginBinding activityPluginBinding;
    private ActivityResultLauncher<Intent> documentActivityResultLauncher;
    private boolean legacyActivityResultListenerRegistered;

    private volatile EventChannel.EventSink eventSink;
    private final FFmpegKitFlutterMethodResultHandler resultHandler;

    // "ffkit" protocol object registries, keyed by the generated protocol url.
    // The native objects are stateful and must be kept alive between the create
    // call and the subsequent read/write/close calls.
    private final Map<String, FFmpegKitInputBuffer> inputBufferRegistry = new ConcurrentHashMap<>();
    private final Map<String, FFmpegKitOutputBuffer> outputBufferRegistry = new ConcurrentHashMap<>();
    private final Map<String, FFmpegKitStreamInput> streamInputRegistry = new ConcurrentHashMap<>();
    private final Map<String, FFmpegKitStreamOutput> streamOutputRegistry = new ConcurrentHashMap<>();

    public FFmpegKitFlutterPlugin() {
        this.logsEnabled = new AtomicBoolean(false);
        this.statisticsEnabled = new AtomicBoolean(false);
        this.asyncExecutorService = Executors.newFixedThreadPool(asyncConcurrencyLimit);
        this.resultHandler = new FFmpegKitFlutterMethodResultHandler();

        Log.d(LIBRARY_NAME, String.format("FFmpegKitFlutterPlugin created %s.", this));
    }

    @Override
    public void onAttachedToEngine(@NonNull final FlutterPluginBinding flutterPluginBinding) {
        this.flutterPluginBinding = flutterPluginBinding;
        init(flutterPluginBinding.getBinaryMessenger(), flutterPluginBinding.getApplicationContext());
    }

    @Override
    public void onDetachedFromEngine(@NonNull final FlutterPluginBinding binding) {
        uninit();
        this.flutterPluginBinding = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding activityPluginBinding) {
        Log.d(LIBRARY_NAME, String.format("FFmpegKitFlutterPlugin %s attached to activity %s.", this, activityPluginBinding.getActivity()));
        attachActivity(activityPluginBinding.getActivity(), activityPluginBinding);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding activityPluginBinding) {
        onAttachedToActivity(activityPluginBinding);
    }

    @Override
    public void onDetachedFromActivity() {
        detachActivity();
        Log.d(LIBRARY_NAME, "FFmpegKitFlutterPlugin detached from activity.");
    }

    @Override
    public void onListen(final Object o, final EventChannel.EventSink eventSink) {
        this.eventSink = eventSink;
        Log.d(LIBRARY_NAME, String.format("FFmpegKitFlutterPlugin %s started listening to events on %s.", this, eventSink));
    }

    @Override
    public void onCancel(final Object o) {
        this.eventSink = null;
        Log.d(LIBRARY_NAME, "FFmpegKitFlutterPlugin stopped listening to events.");
    }

    @Override
    public boolean onActivityResult(final int requestCode, final int resultCode, final Intent data) {
        Log.d(LIBRARY_NAME, String.format("selectDocument completed with requestCode: %d, resultCode: %d, data: %s.", requestCode, resultCode, data == null ? null : data.toString()));

        if (requestCode == READABLE_REQUEST_CODE || requestCode == WRITABLE_REQUEST_CODE) {
            handleSelectDocumentResult(resultCode, data);
            return true;
        } else {
            Log.i(LIBRARY_NAME, String.format("FFmpegKitFlutterPlugin ignored unsupported activity result for requestCode: %d.", requestCode));
            return false;
        }
    }

    // Fushi: the first FFmpegKitConfig touch loads libffmpegkit.so and the FFmpeg
    // libraries. If an ABI ships without them (or a library fails to link),
    // that throws UnsatisfiedLinkError on the platform thread and kills the app.
    // Probe once and answer every call with FFMPEG_KIT_UNAVAILABLE instead, so
    // KitFfmpegBackend reports a failed run rather than crashing the activity.
    private static final String FFMPEG_KIT_UNAVAILABLE = "FFMPEG_KIT_UNAVAILABLE";
    private volatile Boolean nativeLibraryAvailable;
    private volatile String nativeLibraryUnavailableMessage;

    protected boolean isNativeLibraryAvailable() {
        final Boolean known = nativeLibraryAvailable;
        if (known != null) {
            return known;
        }
        synchronized (this) {
            if (nativeLibraryAvailable == null) {
                try {
                    FFmpegKitConfig.getFFmpegVersion();
                    nativeLibraryUnavailableMessage = null;
                    nativeLibraryAvailable = true;
                } catch (final Throwable t) {
                    nativeLibraryUnavailableMessage = String.format(
                            "FFmpegKit native libraries are not available on this device: %s", t);
                    Log.e(LIBRARY_NAME, nativeLibraryUnavailableMessage, t);
                    nativeLibraryAvailable = false;
                }
            }
            return nativeLibraryAvailable;
        }
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        if (!isNativeLibraryAvailable()) {
            resultHandler.errorAsync(result, FFMPEG_KIT_UNAVAILABLE, nativeLibraryUnavailableMessage);
            return;
        }

        final Integer sessionId = call.argument(ARGUMENT_SESSION_ID);
        final Integer waitTimeout = call.argument(ARGUMENT_WAIT_TIMEOUT);
        final List<String> arguments = call.argument(ARGUMENT_ARGUMENTS);
        final String ffprobeJsonOutput = call.argument(ARGUMENT_FFPROBE_JSON_OUTPUT);
        final Boolean writable = call.argument(ARGUMENT_WRITABLE);

        switch (call.method) {
            case "abstractSessionGetEndTime":
                if (sessionId != null) {
                    abstractSessionGetEndTime(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetDuration":
                if (sessionId != null) {
                    abstractSessionGetDuration(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetAllLogs":
                if (sessionId != null) {
                    abstractSessionGetAllLogs(sessionId, waitTimeout, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetLogs":
                if (sessionId != null) {
                    abstractSessionGetLogs(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetAllLogsAsString":
                if (sessionId != null) {
                    abstractSessionGetAllLogsAsString(sessionId, waitTimeout, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetState":
                if (sessionId != null) {
                    abstractSessionGetState(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetReturnCode":
                if (sessionId != null) {
                    abstractSessionGetReturnCode(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "abstractSessionGetFailStackTrace":
                if (sessionId != null) {
                    abstractSessionGetFailStackTrace(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "thereAreAsynchronousMessagesInTransmit":
                if (sessionId != null) {
                    abstractSessionThereAreAsynchronousMessagesInTransmit(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "getArch":
                getArch(result);
                break;
            case "ffmpegSession":
                if (arguments != null) {
                    ffmpegSession(arguments, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_ARGUMENTS", "Invalid arguments array.");
                }
                break;
            case "ffmpegSessionGetAllStatistics":
                if (sessionId != null) {
                    ffmpegSessionGetAllStatistics(sessionId, waitTimeout, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "ffmpegSessionGetStatistics":
                if (sessionId != null) {
                    ffmpegSessionGetStatistics(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "ffprobeSession":
                if (arguments != null) {
                    ffprobeSession(arguments, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_ARGUMENTS", "Invalid arguments array.");
                }
                break;
            case "mediaInformationSession":
                if (arguments != null) {
                    mediaInformationSession(arguments, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_ARGUMENTS", "Invalid arguments array.");
                }
                break;
            case "getMediaInformation":
                if (sessionId != null) {
                    getMediaInformation(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "mediaInformationJsonParserFrom":
                if (ffprobeJsonOutput != null) {
                    mediaInformationJsonParserFrom(ffprobeJsonOutput, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_FFPROBE_JSON_OUTPUT", "Invalid ffprobe json output.");
                }
                break;
            case "mediaInformationJsonParserFromWithError":
                if (ffprobeJsonOutput != null) {
                    mediaInformationJsonParserFromWithError(ffprobeJsonOutput, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_FFPROBE_JSON_OUTPUT", "Invalid ffprobe json output.");
                }
                break;
            case "enableRedirection":
                enableRedirection(result);
                break;
            case "disableRedirection":
                disableRedirection(result);
                break;
            case "enableLogs":
                enableLogs(result);
                break;
            case "disableLogs":
                disableLogs(result);
                break;
            case "enableStatistics":
                enableStatistics(result);
                break;
            case "disableStatistics":
                disableStatistics(result);
                break;
            case "setFontconfigConfigurationPath":
                final String path = call.argument("path");
                if (path != null) {
                    setFontconfigConfigurationPath(path, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_PATH", "Invalid path.");
                }
                break;
            case "setFontDirectory": {
                final String fontDirectory = call.argument("fontDirectory");
                final Map<String, String> fontNameMap = call.argument("fontNameMap");
                if (fontDirectory != null) {
                    setFontDirectory(fontDirectory, fontNameMap, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_FONT_DIRECTORY", "Invalid font directory.");
                }
                break;
            }
            case "setFontDirectoryList": {
                final List<String> fontDirectoryList = call.argument("fontDirectoryList");
                final Map<String, String> fontNameMap = call.argument("fontNameMap");
                if (fontDirectoryList != null) {
                    setFontDirectoryList(fontDirectoryList, fontNameMap, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_FONT_DIRECTORY_LIST", "Invalid font directory list.");
                }
                break;
            }
            case "registerNewFFmpegPipe":
                registerNewFFmpegPipe(result);
                break;
            case "closeFFmpegPipe":
                final String ffmpegPipePath = call.argument("ffmpegPipePath");
                if (ffmpegPipePath != null) {
                    closeFFmpegPipe(ffmpegPipePath, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_PIPE_PATH", "Invalid ffmpeg pipe path.");
                }
                break;
            case "getFFmpegVersion":
                getFFmpegVersion(result);
                break;
            case "isLTSBuild":
                isLTSBuild(result);
                break;
            case "getBuildDate":
                getBuildDate(result);
                break;
            case "setEnvironmentVariable":
                final String variableName = call.argument("variableName");
                final String variableValue = call.argument("variableValue");

                if (variableName != null && variableValue != null) {
                    setEnvironmentVariable(variableName, variableValue, result);
                } else if (variableValue != null) {
                    resultHandler.errorAsync(result, "INVALID_NAME", "Invalid environment variable name.");
                } else {
                    resultHandler.errorAsync(result, "INVALID_VALUE", "Invalid environment variable value.");
                }
                break;
            case "ignoreSignal":
                final Integer signal = call.argument("signal");
                if (signal != null) {
                    ignoreSignal(signal, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SIGNAL", "Invalid signal value.");
                }
                break;
            case "ffmpegSessionExecute":
                if (sessionId != null) {
                    ffmpegSessionExecute(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "ffprobeSessionExecute":
                if (sessionId != null) {
                    ffprobeSessionExecute(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "mediaInformationSessionExecute":
                if (sessionId != null) {
                    mediaInformationSessionExecute(sessionId, waitTimeout, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "asyncFFmpegSessionExecute":
                if (sessionId != null) {
                    asyncFFmpegSessionExecute(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "asyncFFprobeSessionExecute":
                if (sessionId != null) {
                    asyncFFprobeSessionExecute(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "asyncMediaInformationSessionExecute":
                if (sessionId != null) {
                    asyncMediaInformationSessionExecute(sessionId, waitTimeout, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "getLogLevel":
                getLogLevel(result);
                break;
            case "printLoadConfirmation":
                printLoadConfirmation(result);
                break;
            case "setLogLevel":
                final Integer level = call.argument("level");
                if (level != null) {
                    setLogLevel(level, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_LEVEL", "Invalid level value.");
                }
                break;
            case "getSessionHistorySize":
                getSessionHistorySize(result);
                break;
            case "setSessionHistorySize":
                final Integer sessionHistorySize = call.argument("sessionHistorySize");
                if (sessionHistorySize != null) {
                    setSessionHistorySize(sessionHistorySize, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SIZE", "Invalid session history size value.");
                }
                break;
            case "getSession":
                if (sessionId != null) {
                    getSession(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "getLastSession":
                getLastSession(result);
                break;
            case "getLastCompletedSession":
                getLastCompletedSession(result);
                break;
            case "getSessions":
                getSessions(result);
                break;
            case "clearSessions":
                clearSessions(result);
                break;
            case "deleteSession":
                if (sessionId != null) {
                    deleteSession(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "getSessionsByState":
                final Integer state = call.argument("state");
                if (state != null) {
                    getSessionsByState(state, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION_STATE", "Invalid session state value.");
                }
                break;
            case "getLogRedirectionStrategy":
                getLogRedirectionStrategy(result);
                break;
            case "setLogRedirectionStrategy":
                final Integer strategy = call.argument("strategy");
                if (strategy != null) {
                    setLogRedirectionStrategy(strategy, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_LOG_REDIRECTION_STRATEGY", "Invalid log redirection strategy value.");
                }
                break;
            case "messagesInTransmit":
                if (sessionId != null) {
                    messagesInTransmit(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "getPlatform":
                getPlatform(result);
                break;
            case "writeToPipe":
                final String input = call.argument("input");
                final String pipe = call.argument("pipe");
                if (input != null && pipe != null) {
                    writeToPipe(input, pipe, result);
                } else if (pipe != null) {
                    resultHandler.errorAsync(result, "INVALID_INPUT", "Invalid input value.");
                } else {
                    resultHandler.errorAsync(result, "INVALID_PIPE", "Invalid pipe value.");
                }
                break;
            case "selectDocument":
                final String title = call.argument("title");
                final String type = call.argument("type");
                final List<String> extraTypes = call.argument("extraTypes");
                final String[] extraTypesArray;
                if (extraTypes != null) {
                    extraTypesArray = extraTypes.toArray(new String[0]);
                } else {
                    extraTypesArray = null;
                }
                if (writable != null) {
                    selectDocument(writable, title, type, extraTypesArray, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_WRITABLE", "Invalid writable value.");
                }
                break;
            case "getSafParameter":
                final String uri = call.argument("uri");
                final String openMode = call.argument("openMode");
                final Boolean reusable = call.argument("reusable");
                if (uri != null && openMode != null) {
                    getSafParameter(uri, openMode, reusable, result);
                } else if (uri != null) {
                    resultHandler.errorAsync(result, "INVALID_OPEN_MODE", "Invalid openMode value.");
                } else {
                    resultHandler.errorAsync(result, "INVALID_URI", "Invalid uri value.");
                }
                break;
            case "unregisterSafProtocolUrl":
                final String safUrl = call.argument("safUrl");
                if (safUrl != null) {
                    unregisterSafProtocolUrl(safUrl, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SAF_URL", "Invalid safUrl value.");
                }
                break;
            case "cancel":
                cancel(result);
                break;
            case "cancelSession":
                if (sessionId != null) {
                    cancelSession(sessionId, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_SESSION", "Invalid session id.");
                }
                break;
            case "getFFmpegSessions":
                getFFmpegSessions(result);
                break;
            case "getFFprobeSessions":
                getFFprobeSessions(result);
                break;
            case "getMediaInformationSessions":
                getMediaInformationSessions(result);
                break;
            case "getPackageName":
                getPackageName(result);
                break;
            case "getExternalLibraries":
                getExternalLibraries(result);
                break;
            case "getSupportedCameraIds":
                getSupportedCameraIds(result);
                break;

            // FFmpegKitInputBuffer

            case "inputBufferFromByteArray": {
                final byte[] data = call.argument("data");
                final String extension = call.argument("extension");
                if (data != null) {
                    inputBufferFromByteArray(data, extension, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_DATA", "Invalid input buffer data.");
                }
                break;
            }
            case "inputBufferClose": {
                final String url = call.argument("url");
                if (url != null) {
                    inputBufferClose(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid input buffer url.");
                }
                break;
            }

            // FFmpegKitOutputBuffer

            case "outputBufferCreate": {
                final String extension = call.argument("extension");
                final Number initialCapacity = call.argument("initialCapacity");
                final Number maxCapacity = call.argument("maxCapacity");
                outputBufferCreate(extension, initialCapacity, maxCapacity, result);
                break;
            }
            case "outputBufferGetSize": {
                final String url = call.argument("url");
                if (url != null) {
                    outputBufferGetSize(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid output buffer url.");
                }
                break;
            }
            case "outputBufferToByteArray": {
                final String url = call.argument("url");
                if (url != null) {
                    outputBufferToByteArray(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid output buffer url.");
                }
                break;
            }
            case "outputBufferClose": {
                final String url = call.argument("url");
                if (url != null) {
                    outputBufferClose(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid output buffer url.");
                }
                break;
            }

            // FFmpegKitStreamInput

            case "streamInputCreate": {
                final String extension = call.argument("extension");
                final Number capacity = call.argument("capacity");
                streamInputCreate(extension, capacity, result);
                break;
            }
            case "streamInputWrite": {
                final String url = call.argument("url");
                final byte[] data = call.argument("data");
                final Integer timeoutMs = call.argument("timeoutMs");
                if (url != null && data != null) {
                    streamInputWrite(url, data, timeoutMs, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_ARGUMENTS", "Invalid stream input arguments.");
                }
                break;
            }
            case "streamInputCloseInput": {
                final String url = call.argument("url");
                if (url != null) {
                    streamInputCloseInput(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid stream input url.");
                }
                break;
            }
            case "streamInputClose": {
                final String url = call.argument("url");
                if (url != null) {
                    streamInputClose(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid stream input url.");
                }
                break;
            }

            // FFmpegKitStreamOutput

            case "streamOutputCreate": {
                final String extension = call.argument("extension");
                final Number capacity = call.argument("capacity");
                streamOutputCreate(extension, capacity, result);
                break;
            }
            case "streamOutputRead": {
                final String url = call.argument("url");
                final Integer maxBytes = call.argument("maxBytes");
                final Integer timeoutMs = call.argument("timeoutMs");
                if (url != null && maxBytes != null) {
                    streamOutputRead(url, maxBytes, timeoutMs, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_ARGUMENTS", "Invalid stream output arguments.");
                }
                break;
            }
            case "streamOutputClose": {
                final String url = call.argument("url");
                if (url != null) {
                    streamOutputClose(url, result);
                } else {
                    resultHandler.errorAsync(result, "INVALID_URL", "Invalid stream output url.");
                }
                break;
            }
            default:
                resultHandler.notImplementedAsync(result);
                break;
        }
    }

    protected void init(final BinaryMessenger messenger, final Context context) {
        if (methodChannel == null) {
            methodChannel = new MethodChannel(messenger, METHOD_CHANNEL);
            methodChannel.setMethodCallHandler(this);
        } else {
            Log.i(LIBRARY_NAME, "FFmpegKitFlutterPlugin method channel was already initialised.");
        }

        if (eventChannel == null) {
            eventChannel = new EventChannel(messenger, EVENT_CHANNEL);
            eventChannel.setStreamHandler(this);
        } else {
            Log.i(LIBRARY_NAME, "FFmpegKitFlutterPlugin event channel was already initialised.");
        }

        this.context = context;
        this.sessionDeleteListener = registerSessionDeleteListener();

        Log.d(LIBRARY_NAME, String.format("FFmpegKitFlutterPlugin %s initialised with context %s.", this, context));
    }

    protected void uninit() {
        unregisterSessionDeleteListener();
        uninitMethodChannel();
        uninitEventChannel();
        detachActivity();

        this.eventSink = null;
        this.context = null;

        Log.d(LIBRARY_NAME, "FFmpegKitFlutterPlugin uninitialized.");
    }

    protected void attachActivity(@NonNull final Activity activity, @NonNull final ActivityPluginBinding activityBinding) {
        detachActivity();

        this.activity = activity;
        this.activityPluginBinding = activityBinding;

        registerDocumentActivityResultLauncher(activity, activityBinding);
    }

    protected void detachActivity() {
        if (documentActivityResultLauncher != null) {
            documentActivityResultLauncher.unregister();
            documentActivityResultLauncher = null;
        }

        if (this.activityPluginBinding != null && legacyActivityResultListenerRegistered) {
            this.activityPluginBinding.removeActivityResultListener(this);
        }

        this.activity = null;
        this.activityPluginBinding = null;
        this.legacyActivityResultListenerRegistered = false;
    }

    protected void uninitMethodChannel() {
        if (methodChannel == null) {
            Log.i(LIBRARY_NAME, "FFmpegKitFlutterPlugin method channel was already uninitialised.");
            return;
        }

        methodChannel.setMethodCallHandler(null);
        methodChannel = null;
    }

    protected void uninitEventChannel() {
        if (eventChannel == null) {
            Log.i(LIBRARY_NAME, "FFmpegKitFlutterPlugin event channel was already uninitialised.");
            return;
        }

        eventChannel.setStreamHandler(null);
        eventChannel = null;
    }

    protected void registerDocumentActivityResultLauncher(@NonNull final Activity activity, @NonNull final ActivityPluginBinding activityBinding) {
        if (activity instanceof ActivityResultRegistryOwner) {
            documentActivityResultLauncher = ((ActivityResultRegistryOwner) activity).getActivityResultRegistry().register(
                    "ffmpeg-kit-flutter-select-document-" + System.identityHashCode(this),
                    new ActivityResultContracts.StartActivityForResult(),
                    this::handleSelectDocumentResult);
            legacyActivityResultListenerRegistered = false;
        } else {
            activityBinding.addActivityResultListener(this);
            legacyActivityResultListenerRegistered = true;
        }
    }

    protected void handleSelectDocumentResult(@NonNull final ActivityResult activityResult) {
        handleSelectDocumentResult(activityResult.getResultCode(), activityResult.getData());
    }

    protected void handleSelectDocumentResult(final int resultCode, @Nullable final Intent data) {
        final Result result = lastInitiatedIntentResult;
        lastInitiatedIntentResult = null;

        if (result == null) {
            Log.i(LIBRARY_NAME, "FFmpegKitFlutterPlugin ignored selectDocument result without a pending call.");
            return;
        }

        if (resultCode == Activity.RESULT_OK) {
            final Uri uri = data == null ? null : data.getData();
            resultHandler.successAsync(result, uri == null ? null : uri.toString());
        } else {
            resultHandler.errorAsync(result, "SELECT_CANCELLED", String.valueOf(resultCode));
        }
    }

    // AbstractSession

    protected void abstractSessionGetEndTime(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            final Date endTime = session.getEndTime();
            if (endTime == null) {
                resultHandler.successAsync(result, null);
            } else {
                resultHandler.successAsync(result, endTime.getTime());
            }
        }
    }

    protected void abstractSessionGetDuration(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            resultHandler.successAsync(result, session.getDuration());
        }
    }

    protected void abstractSessionGetAllLogs(@NonNull final Integer sessionId, @Nullable final Integer waitTimeout, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            final int timeout;
            if (isValidPositiveNumber(waitTimeout)) {
                timeout = waitTimeout;
            } else {
                timeout = AbstractSession.DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT;
            }
            final List<com.arthenica.ffmpegkit.Log> allLogs = session.getAllLogs(timeout);
            resultHandler.successAsync(result, toLogMapList(allLogs));
        }
    }

    protected void abstractSessionGetLogs(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            final List<com.arthenica.ffmpegkit.Log> allLogs = session.getLogs();
            resultHandler.successAsync(result, toLogMapList(allLogs));
        }
    }

    protected void abstractSessionGetAllLogsAsString(@NonNull final Integer sessionId, @Nullable final Integer waitTimeout, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            final int timeout;
            if (isValidPositiveNumber(waitTimeout)) {
                timeout = waitTimeout;
            } else {
                timeout = AbstractSession.DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT;
            }
            final String allLogsAsString = session.getAllLogsAsString(timeout);
            resultHandler.successAsync(result, allLogsAsString);
        }
    }

    protected void abstractSessionGetState(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            resultHandler.successAsync(result, session.getState().ordinal());
        }
    }

    protected void abstractSessionGetReturnCode(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            final ReturnCode returnCode = session.getReturnCode();
            if (returnCode == null) {
                resultHandler.successAsync(result, null);
            } else {
                resultHandler.successAsync(result, returnCode.getValue());
            }
        }
    }

    protected void abstractSessionGetFailStackTrace(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            resultHandler.successAsync(result, session.getFailStackTrace());
        }
    }

    protected void abstractSessionThereAreAsynchronousMessagesInTransmit(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            resultHandler.successAsync(result, session.thereAreAsynchronousMessagesInTransmit());
        }
    }

    // ArchDetect

    protected void getArch(@NonNull final Result result) {
        resultHandler.successAsync(result, AbiDetect.getAbi());
    }

    // FFmpegSession

    protected void ffmpegSession(@NonNull final List<String> arguments, @NonNull final Result result) {
        final FFmpegSession session = FFmpegSession.create(arguments.toArray(new String[0]), this::emitSession, this::emitLogIfEnabled, this::emitStatisticsIfEnabled, LogRedirectionStrategy.NEVER_PRINT_LOGS);
        resultHandler.successAsync(result, toMap(session));
    }

    protected void ffmpegSessionGetAllStatistics(@NonNull final Integer sessionId, @Nullable final Integer waitTimeout, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isFFmpeg()) {
                final int timeout;
                if (isValidPositiveNumber(waitTimeout)) {
                    timeout = waitTimeout;
                } else {
                    timeout = AbstractSession.DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT;
                }
                final List<Statistics> allStatistics = ((FFmpegSession) session).getAllStatistics(timeout);
                resultHandler.successAsync(result, toStatisticsMapList(allStatistics));
            } else {
                resultHandler.errorAsync(result, "NOT_FFMPEG_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void ffmpegSessionGetStatistics(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isFFmpeg()) {
                final List<Statistics> statistics = ((FFmpegSession) session).getStatistics();
                resultHandler.successAsync(result, toStatisticsMapList(statistics));
            } else {
                resultHandler.errorAsync(result, "NOT_FFMPEG_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    // FFprobeSession

    protected void ffprobeSession(@NonNull final List<String> arguments, @NonNull final Result result) {
        final FFprobeSession session = FFprobeSession.create(arguments.toArray(new String[0]), this::emitSession, this::emitLogIfEnabled, LogRedirectionStrategy.NEVER_PRINT_LOGS);
        resultHandler.successAsync(result, toMap(session));
    }

    // MediaInformationSession

    protected void mediaInformationSession(@NonNull final List<String> arguments, @NonNull final Result result) {
        final MediaInformationSession session = MediaInformationSession.create(arguments.toArray(new String[0]), this::emitSession, this::emitLogIfEnabled);
        resultHandler.successAsync(result, toMap(session));
    }

    protected void getMediaInformation(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isMediaInformation()) {
                final MediaInformationSession mediaInformationSession = (MediaInformationSession) session;
                final MediaInformation mediaInformation = mediaInformationSession.getMediaInformation();
                resultHandler.successAsync(result, toMap(mediaInformation));
            } else {
                resultHandler.errorAsync(result, "NOT_MEDIA_INFORMATION_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    // MediaInformationJsonParser

    protected void mediaInformationJsonParserFrom(@NonNull final String ffprobeJsonOutput, @NonNull final Result result) {
        try {
            final MediaInformation mediaInformation = MediaInformationJsonParser.fromWithError(ffprobeJsonOutput);
            resultHandler.successAsync(result, toMap(mediaInformation));
        } catch (final JSONException e) {
            Log.i(LIBRARY_NAME, "Parsing MediaInformation failed.", e);
            resultHandler.successAsync(result, null);
        }
    }

    protected void mediaInformationJsonParserFromWithError(@NonNull final String ffprobeJsonOutput, @NonNull final Result result) {
        try {
            final MediaInformation mediaInformation = MediaInformationJsonParser.fromWithError(ffprobeJsonOutput);
            resultHandler.successAsync(result, toMap(mediaInformation));
        } catch (JSONException e) {
            Log.i(LIBRARY_NAME, "Parsing MediaInformation failed.", e);
            resultHandler.errorAsync(result, "PARSE_FAILED", "Parsing MediaInformation failed with JSON error.");
        }
    }

    // FFmpegKitConfig

    protected void enableRedirection(@NonNull final Result result) {
        enableLogs();
        enableStatistics();
        FFmpegKitConfig.enableRedirection();

        resultHandler.successAsync(result, null);
    }

    protected void disableRedirection(@NonNull final Result result) {
        FFmpegKitConfig.disableRedirection();

        resultHandler.successAsync(result, null);
    }

    protected void enableLogs(@NonNull final Result result) {
        enableLogs();

        resultHandler.successAsync(result, null);
    }

    protected void disableLogs(@NonNull final Result result) {
        disableLogs();

        resultHandler.successAsync(result, null);
    }

    protected void enableStatistics(@NonNull final Result result) {
        enableStatistics();

        resultHandler.successAsync(result, null);
    }

    protected void disableStatistics(@NonNull final Result result) {
        disableStatistics();

        resultHandler.successAsync(result, null);
    }

    protected void setFontconfigConfigurationPath(@NonNull final String path, @NonNull final Result result) {
        FFmpegKitConfig.setFontconfigConfigurationPath(path);

        resultHandler.successAsync(result, null);
    }

    protected void setFontDirectory(@NonNull final String fontDirectoryPath, @Nullable final Map<String, String> fontNameMapping, @NonNull final Result result) {
        if (context != null) {
            FFmpegKitConfig.setFontDirectory(context, fontDirectoryPath, fontNameMapping);
            resultHandler.successAsync(result, null);
        } else {
            Log.w(LIBRARY_NAME, "Cannot setFontDirectory. Context is null.");
            resultHandler.errorAsync(result, "INVALID_CONTEXT", "Context is null.");
        }
    }

    protected void setFontDirectoryList(@NonNull final List<String> fontDirectoryList, @Nullable final Map<String, String> fontNameMapping, @NonNull final Result result) {
        if (context != null) {
            FFmpegKitConfig.setFontDirectoryList(context, fontDirectoryList, fontNameMapping);
            resultHandler.successAsync(result, null);
        } else {
            Log.w(LIBRARY_NAME, "Cannot setFontDirectoryList. Context is null.");
            resultHandler.errorAsync(result, "INVALID_CONTEXT", "Context is null.");
        }
    }

    protected void registerNewFFmpegPipe(@NonNull final Result result) {
        if (context != null) {
            resultHandler.successAsync(result, FFmpegKitConfig.registerNewFFmpegPipe(context));
        } else {
            Log.w(LIBRARY_NAME, "Cannot registerNewFFmpegPipe. Context is null.");
            resultHandler.errorAsync(result, "INVALID_CONTEXT", "Context is null.");
        }
    }

    protected void closeFFmpegPipe(@NonNull final String ffmpegPipePath, @NonNull final Result result) {
        FFmpegKitConfig.closeFFmpegPipe(ffmpegPipePath);

        resultHandler.successAsync(result, null);
    }

    protected void getFFmpegVersion(@NonNull final Result result) {
        resultHandler.successAsync(result, FFmpegKitConfig.getFFmpegVersion());
    }

    @SuppressWarnings("deprecation")
    protected void isLTSBuild(@NonNull final Result result) {
        resultHandler.successAsync(result, FFmpegKitConfig.isLTSBuild());
    }

    protected void getBuildDate(@NonNull final Result result) {
        resultHandler.successAsync(result, FFmpegKitConfig.getBuildDate());
    }

    protected void setEnvironmentVariable(@NonNull final String variableName, @NonNull final String variableValue, @NonNull final Result result) {
        FFmpegKitConfig.setEnvironmentVariable(variableName, variableValue);

        resultHandler.successAsync(result, null);
    }

    protected void ignoreSignal(@NonNull final Integer signalIndex, @NonNull final Result result) {
        Signal signal = null;

        if (signalIndex == Signal.SIGINT.ordinal()) {
            signal = Signal.SIGINT;
        } else if (signalIndex == Signal.SIGQUIT.ordinal()) {
            signal = Signal.SIGQUIT;
        } else if (signalIndex == Signal.SIGPIPE.ordinal()) {
            signal = Signal.SIGPIPE;
        } else if (signalIndex == Signal.SIGTERM.ordinal()) {
            signal = Signal.SIGTERM;
        } else if (signalIndex == Signal.SIGXCPU.ordinal()) {
            signal = Signal.SIGXCPU;
        }

        if (signal != null) {
            FFmpegKitConfig.ignoreSignal(signal);

            resultHandler.successAsync(result, null);
        } else {
            resultHandler.errorAsync(result, "INVALID_SIGNAL", "Signal value not supported.");
        }
    }

    protected void ffmpegSessionExecute(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isFFmpeg()) {
                final FFmpegSessionExecuteTask ffmpegSessionExecuteTask = new FFmpegSessionExecuteTask((FFmpegSession) session, resultHandler, result);
                asyncExecutorService.submit(ffmpegSessionExecuteTask);
            } else {
                resultHandler.errorAsync(result, "NOT_FFMPEG_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void ffprobeSessionExecute(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isFFprobe()) {
                final FFprobeSessionExecuteTask ffprobeSessionExecuteTask = new FFprobeSessionExecuteTask((FFprobeSession) session, resultHandler, result);
                asyncExecutorService.submit(ffprobeSessionExecuteTask);
            } else {
                resultHandler.errorAsync(result, "NOT_FFPROBE_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void mediaInformationSessionExecute(@NonNull final Integer sessionId, @Nullable final Integer waitTimeout, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isMediaInformation()) {
                final int timeout;
                if (isValidPositiveNumber(waitTimeout)) {
                    timeout = waitTimeout;
                } else {
                    timeout = AbstractSession.DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT;
                }
                final MediaInformationSessionExecuteTask mediaInformationSessionExecuteTask = new MediaInformationSessionExecuteTask((MediaInformationSession) session, timeout, resultHandler, result);
                asyncExecutorService.submit(mediaInformationSessionExecuteTask);
            } else {
                resultHandler.errorAsync(result, "NOT_MEDIA_INFORMATION_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void asyncFFmpegSessionExecute(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isFFmpeg()) {
                FFmpegKitConfig.asyncFFmpegExecute((FFmpegSession) session);
                resultHandler.successAsync(result, null);
            } else {
                resultHandler.errorAsync(result, "NOT_FFMPEG_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void asyncFFprobeSessionExecute(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isFFprobe()) {
                FFmpegKitConfig.asyncFFprobeExecute((FFprobeSession) session);
                resultHandler.successAsync(result, null);
            } else {
                resultHandler.errorAsync(result, "NOT_FFPROBE_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void asyncMediaInformationSessionExecute(@NonNull final Integer sessionId, @Nullable final Integer waitTimeout, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            if (session.isMediaInformation()) {
                final int timeout;
                if (isValidPositiveNumber(waitTimeout)) {
                    timeout = waitTimeout;
                } else {
                    timeout = AbstractSession.DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT;
                }
                FFmpegKitConfig.asyncGetMediaInformationExecute((MediaInformationSession) session, timeout);
                resultHandler.successAsync(result, null);
            } else {
                resultHandler.errorAsync(result, "NOT_MEDIA_INFORMATION_SESSION", "A session is found but it does not have the correct type.");
            }
        }
    }

    protected void getLogLevel(@NonNull final Result result) {
        resultHandler.successAsync(result, toInt(FFmpegKitConfig.getLogLevel()));
    }

    protected void printLoadConfirmation(@NonNull final Result result) {
        if (loadedLogged.compareAndSet(false, true)) {
            final String packageName = Packages.getPackageName();
            final String packageNamePart = packageName.isEmpty() ? "" : packageName + "-";
            Log.d(LIBRARY_NAME, String.format("Loaded ffmpeg-kit-next-flutter-%s%s-%s-%s.", packageNamePart, PLATFORM_NAME, AbiDetect.getAbi(), LIBRARY_VERSION));
        }

        resultHandler.successAsync(result, null);
    }

    protected void setLogLevel(@NonNull final Integer level, @NonNull final Result result) {
        FFmpegKitConfig.setLogLevel(Level.from(level));
        resultHandler.successAsync(result, null);
    }

    protected void getSessionHistorySize(@NonNull final Result result) {
        resultHandler.successAsync(result, FFmpegKitConfig.getSessionHistorySize());
    }

    protected void setSessionHistorySize(@NonNull final Integer sessionHistorySize, @NonNull final Result result) {
        FFmpegKitConfig.setSessionHistorySize(sessionHistorySize);
        resultHandler.successAsync(result, null);
    }

    protected void getSession(@NonNull final Integer sessionId, @NonNull final Result result) {
        final Session session = FFmpegKitConfig.getSession(sessionId.longValue());
        if (session == null) {
            resultHandler.errorAsync(result, "SESSION_NOT_FOUND", "Session not found.");
        } else {
            resultHandler.successAsync(result, toMap(session));
        }
    }

    protected void getLastSession(@NonNull final Result result) {
        final Session session = FFmpegKitConfig.getLastSession();
        resultHandler.successAsync(result, toMap(session));
    }

    protected void getLastCompletedSession(@NonNull final Result result) {
        final Session session = FFmpegKitConfig.getLastCompletedSession();
        resultHandler.successAsync(result, toMap(session));
    }

    protected void getSessions(@NonNull final Result result) {
        resultHandler.successAsync(result, toSessionMapList(FFmpegKitConfig.getSessions()));
    }

    protected void clearSessions(@NonNull final Result result) {
        FFmpegKitConfig.clearSessions();
        resultHandler.successAsync(result, null);
    }

    protected void deleteSession(@NonNull final Number sessionId, @NonNull final Result result) {
        FFmpegKitConfig.deleteSession(sessionId.longValue());
        resultHandler.successAsync(result, null);
    }

    protected void getSessionsByState(@NonNull final Integer sessionState, @NonNull final Result result) {
        resultHandler.successAsync(result, toSessionMapList(FFmpegKitConfig.getSessionsByState(toSessionState(sessionState))));
    }

    protected void getLogRedirectionStrategy(@NonNull final Result result) {
        resultHandler.successAsync(result, toInt(FFmpegKitConfig.getLogRedirectionStrategy()));
    }

    protected void setLogRedirectionStrategy(@NonNull final Integer logRedirectionStrategy, @NonNull final Result result) {
        FFmpegKitConfig.setLogRedirectionStrategy(toLogRedirectionStrategy(logRedirectionStrategy));
        resultHandler.successAsync(result, null);
    }

    protected void messagesInTransmit(@NonNull final Integer sessionId, @NonNull final Result result) {
        resultHandler.successAsync(result, FFmpegKitConfig.messagesInTransmit(sessionId.longValue()));
    }

    protected void getPlatform(@NonNull final Result result) {
        resultHandler.successAsync(result, PLATFORM_NAME);
    }

    protected void writeToPipe(@NonNull final String inputPath, @NonNull final String namedPipePath, @NonNull final Result result) {
        final WriteToPipeTask asyncTask = new WriteToPipeTask(inputPath, namedPipePath, resultHandler, result);
        asyncExecutorService.submit(asyncTask);
    }

    // FFmpegKitInputBuffer

    protected void inputBufferFromByteArray(@NonNull final byte[] data, @Nullable final String extension, @NonNull final Result result) {
        final FFmpegKitInputBuffer inputBuffer = FFmpegKitInputBuffer.fromByteArray(data, extension);
        final String url = inputBuffer.getUrl();
        inputBufferRegistry.put(url, inputBuffer);
        resultHandler.successAsync(result, url);
    }

    protected void inputBufferClose(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitInputBuffer inputBuffer = inputBufferRegistry.remove(url);
        if (inputBuffer != null) {
            inputBuffer.close();
        }
        resultHandler.successAsync(result, null);
    }

    // FFmpegKitOutputBuffer

    protected void outputBufferCreate(@Nullable final String extension, @Nullable final Number initialCapacity, @Nullable final Number maxCapacity, @NonNull final Result result) {
        final FFmpegKitOutputBuffer outputBuffer;
        if (initialCapacity != null && maxCapacity != null) {
            outputBuffer = FFmpegKitOutputBuffer.create(extension, initialCapacity.longValue(), maxCapacity.longValue());
        } else {
            outputBuffer = FFmpegKitOutputBuffer.create(extension);
        }
        final String url = outputBuffer.getUrl();
        outputBufferRegistry.put(url, outputBuffer);
        resultHandler.successAsync(result, url);
    }

    protected void outputBufferGetSize(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitOutputBuffer outputBuffer = outputBufferRegistry.get(url);
        if (outputBuffer != null) {
            resultHandler.successAsync(result, outputBuffer.getSize());
        } else {
            resultHandler.errorAsync(result, "NOT_FOUND", "Output buffer not found.");
        }
    }

    protected void outputBufferToByteArray(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitOutputBuffer outputBuffer = outputBufferRegistry.get(url);
        if (outputBuffer != null) {
            resultHandler.successAsync(result, outputBuffer.toByteArray());
        } else {
            resultHandler.errorAsync(result, "NOT_FOUND", "Output buffer not found.");
        }
    }

    protected void outputBufferClose(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitOutputBuffer outputBuffer = outputBufferRegistry.remove(url);
        if (outputBuffer != null) {
            outputBuffer.close();
        }
        resultHandler.successAsync(result, null);
    }

    // FFmpegKitStreamInput

    protected void streamInputCreate(@Nullable final String extension, @Nullable final Number capacity, @NonNull final Result result) {
        final FFmpegKitStreamInput streamInput;
        if (capacity != null) {
            streamInput = FFmpegKitStreamInput.create(extension, capacity.longValue());
        } else {
            streamInput = FFmpegKitStreamInput.create(extension);
        }
        final String url = streamInput.getUrl();
        streamInputRegistry.put(url, streamInput);
        resultHandler.successAsync(result, url);
    }

    protected void streamInputWrite(@NonNull final String url, @NonNull final byte[] data, @Nullable final Integer timeoutMs, @NonNull final Result result) {
        final FFmpegKitStreamInput streamInput = streamInputRegistry.get(url);
        if (streamInput == null) {
            resultHandler.errorAsync(result, "NOT_FOUND", "Stream input not found.");
            return;
        }
        asyncExecutorService.submit(() -> {
            try {
                final int written = (timeoutMs != null) ? streamInput.write(data, timeoutMs) : streamInput.write(data);
                resultHandler.successAsync(result, written);
            } catch (final Exception e) {
                resultHandler.errorAsync(result, "STREAM_INPUT_WRITE_FAILED", e.getMessage());
            }
        });
    }

    protected void streamInputCloseInput(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitStreamInput streamInput = streamInputRegistry.get(url);
        if (streamInput != null) {
            streamInput.closeInput();
        }
        resultHandler.successAsync(result, null);
    }

    protected void streamInputClose(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitStreamInput streamInput = streamInputRegistry.remove(url);
        if (streamInput != null) {
            streamInput.close();
        }
        resultHandler.successAsync(result, null);
    }

    // FFmpegKitStreamOutput

    protected void streamOutputCreate(@Nullable final String extension, @Nullable final Number capacity, @NonNull final Result result) {
        final FFmpegKitStreamOutput streamOutput;
        if (capacity != null) {
            streamOutput = FFmpegKitStreamOutput.create(extension, capacity.longValue());
        } else {
            streamOutput = FFmpegKitStreamOutput.create(extension);
        }
        final String url = streamOutput.getUrl();
        streamOutputRegistry.put(url, streamOutput);
        resultHandler.successAsync(result, url);
    }

    protected void streamOutputRead(@NonNull final String url, @NonNull final Integer maxBytes, @Nullable final Integer timeoutMs, @NonNull final Result result) {
        final FFmpegKitStreamOutput streamOutput = streamOutputRegistry.get(url);
        if (streamOutput == null) {
            resultHandler.errorAsync(result, "NOT_FOUND", "Stream output not found.");
            return;
        }
        asyncExecutorService.submit(() -> {
            try {
                final byte[] data = (timeoutMs != null) ? streamOutput.read(maxBytes, timeoutMs) : streamOutput.read(maxBytes);
                resultHandler.successAsync(result, data);
            } catch (final Exception e) {
                resultHandler.errorAsync(result, "STREAM_OUTPUT_READ_FAILED", e.getMessage());
            }
        });
    }

    protected void streamOutputClose(@NonNull final String url, @NonNull final Result result) {
        final FFmpegKitStreamOutput streamOutput = streamOutputRegistry.remove(url);
        if (streamOutput != null) {
            streamOutput.close();
        }
        resultHandler.successAsync(result, null);
    }

    protected void selectDocument(@NonNull final Boolean writable, @Nullable final String title, @Nullable final String type, @Nullable final String[] extraTypes, @NonNull final Result result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.KITKAT) {
            android.util.Log.i(LIBRARY_NAME, String.format(Locale.getDefault(), "selectDocument is not supported on API Level %d", Build.VERSION.SDK_INT));
            resultHandler.errorAsync(result, "SELECT_FAILED", String.format(Locale.getDefault(), "selectDocument is not supported on API Level %d", Build.VERSION.SDK_INT));
            return;
        }

        final Intent intent;
        if (writable) {
            intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } else {
            intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        }

        if (type != null) {
            intent.setType(type);
        } else {
            intent.setType("*/*");
        }

        if (title != null) {
            intent.putExtra(Intent.EXTRA_TITLE, title);
        }

        if (extraTypes != null) {
            intent.putExtra(Intent.EXTRA_MIME_TYPES, extraTypes);
        }

        if (context != null) {
            if (activity != null) {
                try {
                    lastInitiatedIntentResult = result;
                    if (documentActivityResultLauncher != null) {
                        documentActivityResultLauncher.launch(intent);
                    } else {
                        startSelectDocumentActivityForResult(intent, writable ? WRITABLE_REQUEST_CODE : READABLE_REQUEST_CODE);
                    }
                } catch (final Exception e) {
                    lastInitiatedIntentResult = null;
                    Log.i(LIBRARY_NAME, String.format("Failed to selectDocument using parameters writable: %s, type: %s, title: %s and extra types: %s!", writable, type, title, extraTypes == null ? null : Arrays.toString(extraTypes)), e);
                    resultHandler.errorAsync(result, "SELECT_FAILED", e.getMessage());
                }
            } else {
                Log.w(LIBRARY_NAME, String.format("Cannot selectDocument using parameters writable: %s, type: %s, title: %s and extra types: %s. Activity is null.", writable, type, title, extraTypes == null ? null : Arrays.toString(extraTypes)));
                resultHandler.errorAsync(result, "INVALID_ACTIVITY", "Activity is null.");
            }
        } else {
            Log.w(LIBRARY_NAME, String.format("Cannot selectDocument using parameters writable: %s, type: %s, title: %s and extra types: %s. Context is null.", writable, type, title, extraTypes == null ? null : Arrays.toString(extraTypes)));
            resultHandler.errorAsync(result, "INVALID_CONTEXT", "Context is null.");
        }
    }

    @SuppressWarnings("deprecation")
    protected void startSelectDocumentActivityForResult(@NonNull final Intent intent, final int requestCode) {
        activity.startActivityForResult(intent, requestCode);
    }

    protected void getSafParameter(@NonNull final String uriString, @NonNull final String openMode, @Nullable final Boolean reusable, @NonNull final Result result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.KITKAT) {
            android.util.Log.i(LIBRARY_NAME, String.format(Locale.getDefault(), "getSafParameter is not supported on API Level %d", Build.VERSION.SDK_INT));
            resultHandler.errorAsync(result, "GET_SAF_PARAMETER_FAILED", String.format(Locale.getDefault(), "getSafParameter is not supported on API Level %d", Build.VERSION.SDK_INT));
            return;
        }

        if (context != null) {
            final Uri uri = Uri.parse(uriString);
            if (uri == null) {
                Log.w(LIBRARY_NAME, String.format("Cannot getSafParameter using parameters uriString: %s, openMode: %s. Uri string cannot be parsed.", uriString, openMode));
                resultHandler.errorAsync(result, "GET_SAF_PARAMETER_FAILED", "Uri string cannot be parsed.");
            } else {
                final String safParameter = (reusable != null)
                        ? FFmpegKitConfig.getSafParameter(context, uri, openMode, reusable)
                        : FFmpegKitConfig.getSafParameter(context, uri, openMode);

                Log.d(LIBRARY_NAME, String.format("getSafParameter using parameters uriString: %s, openMode: %s, reusable: %s completed with saf parameter: %s.", uriString, openMode, reusable, safParameter));

                resultHandler.successAsync(result, safParameter);
            }
        } else {
            Log.w(LIBRARY_NAME, String.format("Cannot getSafParameter using parameters uriString: %s, openMode: %s. Context is null.", uriString, openMode));
            resultHandler.errorAsync(result, "INVALID_CONTEXT", "Context is null.");
        }
    }

    protected void unregisterSafProtocolUrl(@NonNull final String safUrl, @NonNull final Result result) {
        FFmpegKitConfig.unregisterSafProtocolUrl(safUrl);

        Log.d(LIBRARY_NAME, String.format("unregisterSafProtocolUrl using parameter safUrl: %s completed.", safUrl));

        resultHandler.successAsync(result, null);
    }

    protected void getSupportedCameraIds(@NonNull final Result result) {
        if (context != null) {
            resultHandler.successAsync(result, FFmpegKitConfig.getSupportedCameraIds(context));
        } else {
            Log.w(LIBRARY_NAME, "Cannot getSupportedCameraIds. Context is null.");
            resultHandler.errorAsync(result, "INVALID_CONTEXT", "Context is null.");
        }
    }

    // FFmpegKit

    protected void cancel(@NonNull final Result result) {
        FFmpegKit.cancel();
        resultHandler.successAsync(result, null);
    }

    protected void cancelSession(@NonNull final Integer sessionId, @NonNull final Result result) {
        FFmpegKit.cancel(sessionId.longValue());
        resultHandler.successAsync(result, null);
    }

    protected void getFFmpegSessions(@NonNull final Result result) {
        resultHandler.successAsync(result, toSessionMapList(FFmpegKit.listSessions()));
    }

    // FFprobeKit

    protected void getFFprobeSessions(@NonNull final Result result) {
        resultHandler.successAsync(result, toSessionMapList(FFprobeKit.listFFprobeSessions()));
    }

    protected void getMediaInformationSessions(@NonNull final Result result) {
        resultHandler.successAsync(result, toSessionMapList(FFprobeKit.listMediaInformationSessions()));
    }

    // Packages

    @SuppressWarnings("deprecation")
    protected void getPackageName(@NonNull final Result result) {
        resultHandler.successAsync(result, Packages.getPackageName());
    }

    protected void getExternalLibraries(@NonNull final Result result) {
        resultHandler.successAsync(result, Packages.getExternalLibraries());
    }

    protected void enableLogs() {
        logsEnabled.compareAndSet(false, true);
    }

    protected void disableLogs() {
        logsEnabled.compareAndSet(true, false);
    }

    protected void enableStatistics() {
        statisticsEnabled.compareAndSet(false, true);
    }

    protected void disableStatistics() {
        statisticsEnabled.compareAndSet(true, false);
    }

    protected static int toInt(final Level level) {
        return (level == null) ? Level.AV_LOG_TRACE.getValue() : level.getValue();
    }

    protected static Map<String, Object> toMap(final Session session) {
        if (session == null) {
            return null;
        }

        final Map<String, Object> sessionMap = new HashMap<>();

        sessionMap.put(KEY_SESSION_ID, session.getSessionId());
        sessionMap.put(KEY_SESSION_CREATE_TIME, toLong(session.getCreateTime()));
        sessionMap.put(KEY_SESSION_START_TIME, toLong(session.getStartTime()));
        sessionMap.put(KEY_SESSION_COMMAND, session.getCommand());

        if (session.isFFmpeg()) {
            sessionMap.put(KEY_SESSION_TYPE, SESSION_TYPE_FFMPEG);
        } else if (session.isFFprobe()) {
            sessionMap.put(KEY_SESSION_TYPE, SESSION_TYPE_FFPROBE);
        } else if (session.isMediaInformation()) {
            final MediaInformationSession mediaInformationSession = (MediaInformationSession) session;
            final MediaInformation mediaInformation = mediaInformationSession.getMediaInformation();
            if (mediaInformation != null) {
                sessionMap.put(KEY_SESSION_MEDIA_INFORMATION, toMap(mediaInformation));
            }
            sessionMap.put(KEY_SESSION_TYPE, SESSION_TYPE_MEDIA_INFORMATION);
        }

        return sessionMap;
    }

    protected static long toLong(final Date date) {
        if (date != null) {
            return date.getTime();
        } else {
            return 0;
        }
    }

    protected static int toInt(final LogRedirectionStrategy logRedirectionStrategy) {
        switch (logRedirectionStrategy) {
            case ALWAYS_PRINT_LOGS:
                return 0;
            case PRINT_LOGS_WHEN_NO_CALLBACKS_DEFINED:
                return 1;
            case PRINT_LOGS_WHEN_GLOBAL_CALLBACK_NOT_DEFINED:
                return 2;
            case PRINT_LOGS_WHEN_SESSION_CALLBACK_NOT_DEFINED:
                return 3;
            case NEVER_PRINT_LOGS:
            default:
                return 4;
        }
    }

    protected static LogRedirectionStrategy toLogRedirectionStrategy(final int value) {
        switch (value) {
            case 0:
                return LogRedirectionStrategy.ALWAYS_PRINT_LOGS;
            case 1:
                return LogRedirectionStrategy.PRINT_LOGS_WHEN_NO_CALLBACKS_DEFINED;
            case 2:
                return LogRedirectionStrategy.PRINT_LOGS_WHEN_GLOBAL_CALLBACK_NOT_DEFINED;
            case 3:
                return LogRedirectionStrategy.PRINT_LOGS_WHEN_SESSION_CALLBACK_NOT_DEFINED;
            case 4:
            default:
                return LogRedirectionStrategy.NEVER_PRINT_LOGS;
        }
    }

    protected static SessionState toSessionState(final int value) {
        switch (value) {
            case 0:
                return SessionState.CREATED;
            case 1:
                return SessionState.RUNNING;
            case 2:
                return SessionState.FAILED;
            case 3:
            default:
                return SessionState.COMPLETED;
        }
    }

    protected static Map<String, Object> toMap(final com.arthenica.ffmpegkit.Log log) {
        final HashMap<String, Object> logMap = new HashMap<>();

        logMap.put(KEY_LOG_SESSION_ID, log.getSessionId());
        logMap.put(KEY_LOG_LEVEL, toInt(log.getLevel()));
        logMap.put(KEY_LOG_MESSAGE, log.getMessage());

        return logMap;
    }

    protected static Map<String, Object> toMap(final Statistics statistics) {
        final HashMap<String, Object> statisticsMap = new HashMap<>();

        if (statistics != null) {
            statisticsMap.put(KEY_STATISTICS_SESSION_ID, statistics.getSessionId());
            statisticsMap.put(KEY_STATISTICS_VIDEO_FRAME_NUMBER, statistics.getVideoFrameNumber());
            statisticsMap.put(KEY_STATISTICS_VIDEO_FPS, statistics.getVideoFps());
            statisticsMap.put(KEY_STATISTICS_VIDEO_QUALITY, statistics.getVideoQuality());
            statisticsMap.put(KEY_STATISTICS_SIZE, (statistics.getSize() < Integer.MAX_VALUE) ? (int) statistics.getSize() : (int) (statistics.getSize() % Integer.MAX_VALUE));
            statisticsMap.put(KEY_STATISTICS_TIME, statistics.getTime());
            statisticsMap.put(KEY_STATISTICS_BITRATE, statistics.getBitrate());
            statisticsMap.put(KEY_STATISTICS_SPEED, statistics.getSpeed());
        }

        return statisticsMap;
    }

    protected static Map<String, Object> toMap(final MediaInformation mediaInformation) {
        if (mediaInformation != null) {
            Map<String, Object> map = new HashMap<>();

            if (mediaInformation.getAllProperties() != null) {
                JSONObject allProperties = mediaInformation.getAllProperties();
                if (allProperties != null) {
                    map = toMap(allProperties);
                }
            }

            return map;
        } else {
            return null;
        }
    }

    protected static Map<String, Object> toMap(final JSONObject jsonObject) {
        final HashMap<String, Object> map = new HashMap<>();

        if (jsonObject != null) {
            Iterator<String> keys = jsonObject.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                Object value = jsonObject.opt(key);
                if (value != null) {
                    if (value instanceof JSONArray) {
                        value = toList((JSONArray) value);
                    } else if (value instanceof JSONObject) {
                        value = toMap((JSONObject) value);
                    }
                    map.put(key, value);
                }
            }
        }

        return map;
    }

    protected static List<Object> toList(final JSONArray array) {
        final List<Object> list = new ArrayList<>();

        for (int i = 0; i < array.length(); i++) {
            Object value = array.opt(i);
            if (value != null) {
                if (value instanceof JSONArray) {
                    value = toList((JSONArray) value);
                } else if (value instanceof JSONObject) {
                    value = toMap((JSONObject) value);
                }
                list.add(value);
            }
        }

        return list;
    }

    protected static List<Map<String, Object>> toSessionMapList(final List<? extends Session> sessionList) {
        final List<Map<String, Object>> list = new ArrayList<>();

        for (int i = 0; i < sessionList.size(); i++) {
            list.add(toMap(sessionList.get(i)));
        }

        return list;
    }

    protected static List<Map<String, Object>> toLogMapList(final List<com.arthenica.ffmpegkit.Log> logList) {
        final List<Map<String, Object>> list = new ArrayList<>();

        for (int i = 0; i < logList.size(); i++) {
            list.add(toMap(logList.get(i)));
        }

        return list;
    }

    protected static List<Map<String, Object>> toStatisticsMapList(final List<com.arthenica.ffmpegkit.Statistics> statisticsList) {
        final List<Map<String, Object>> list = new ArrayList<>();

        for (int i = 0; i < statisticsList.size(); i++) {
            list.add(toMap(statisticsList.get(i)));
        }

        return list;
    }

    protected static boolean isValidPositiveNumber(final Integer value) {
        return (value != null) && (value >= 0);
    }

    protected void emitLogIfEnabled(final com.arthenica.ffmpegkit.Log log) {
        if (logsEnabled.get()) {
            emitLog(log);
        }
    }

    protected void emitStatisticsIfEnabled(final Statistics statistics) {
        if (statisticsEnabled.get()) {
            emitStatistics(statistics);
        }
    }

    protected void emitLog(final com.arthenica.ffmpegkit.Log log) {
        final EventChannel.EventSink sink = eventSink;
        if (sink == null) {
            return;
        }

        final HashMap<String, Object> logMap = new HashMap<>();
        logMap.put(EVENT_LOG_CALLBACK_EVENT, toMap(log));
        resultHandler.successAsync(sink, logMap);
    }

    protected void emitStatistics(final Statistics statistics) {
        final EventChannel.EventSink sink = eventSink;
        if (sink == null) {
            return;
        }

        final HashMap<String, Object> statisticsMap = new HashMap<>();
        statisticsMap.put(EVENT_STATISTICS_CALLBACK_EVENT, toMap(statistics));
        resultHandler.successAsync(sink, statisticsMap);
    }

    protected void emitSession(final Session session) {
        final EventChannel.EventSink sink = eventSink;
        if (sink == null) {
            return;
        }

        final HashMap<String, Object> sessionMap = new HashMap<>();
        sessionMap.put(EVENT_COMPLETE_CALLBACK_EVENT, toMap(session));
        resultHandler.successAsync(sink, sessionMap);
    }

    protected void emitSessionDeleted(final long sessionId) {
        final EventChannel.EventSink sink = eventSink;
        if (sink == null) {
            return;
        }

        final HashMap<String, Object> deletedSession = new HashMap<>();
        deletedSession.put(KEY_SESSION_ID, sessionId);

        final HashMap<String, Object> deletedSessionMap = new HashMap<>();
        deletedSessionMap.put(EVENT_SESSION_DELETED_CALLBACK_EVENT, deletedSession);
        resultHandler.successAsync(sink, deletedSessionMap);
    }

    @Nullable
    private Object registerSessionDeleteListener() {
        if (sessionDeleteListener != null) {
            return sessionDeleteListener;
        }

        try {
            final Class<?> sessionDeleteListenerClass = Class.forName("com.arthenica.ffmpegkit.SessionDeleteListener");
            final Object listener = Proxy.newProxyInstance(
                    sessionDeleteListenerClass.getClassLoader(),
                    new Class<?>[]{sessionDeleteListenerClass},
                    new InvocationHandler() {
                        @Override
                        public Object invoke(final Object proxy, final Method method, final Object[] args) {
                            if (method.getDeclaringClass() == Object.class) {
                                switch (method.getName()) {
                                    case "equals":
                                        return args != null && args.length == 1 && proxy == args[0];
                                    case "hashCode":
                                        return System.identityHashCode(proxy);
                                    case "toString":
                                        return "FFmpegKitFlutterSessionDeleteListener";
                                    default:
                                        return null;
                                }
                            }

                            if ("sessionDeleted".equals(method.getName()) && args != null && args.length == 1 && args[0] instanceof Number) {
                                emitSessionDeleted(((Number) args[0]).longValue());
                            }

                            return null;
                        }
                    });

            FFmpegKitConfig.class.getMethod("addSessionDeleteListener", sessionDeleteListenerClass).invoke(null, listener);
            return listener;
        } catch (final ClassNotFoundException | NoSuchMethodException ignored) {
            return null;
        } catch (final Exception exception) {
            Log.w(LIBRARY_NAME, "Failed to register session delete listener.", exception);
            return null;
        }
    }

    private void unregisterSessionDeleteListener() {
        if (sessionDeleteListener == null) {
            return;
        }

        try {
            final Class<?> sessionDeleteListenerClass = Class.forName("com.arthenica.ffmpegkit.SessionDeleteListener");
            FFmpegKitConfig.class.getMethod("removeSessionDeleteListener", sessionDeleteListenerClass).invoke(null, sessionDeleteListener);
            sessionDeleteListener = null;
        } catch (final ClassNotFoundException | NoSuchMethodException ignored) {
            // The native listener API is optional for compatibility with older native binaries.
        } catch (final Exception exception) {
            Log.w(LIBRARY_NAME, "Failed to unregister session delete listener.", exception);
        }
    }

}
